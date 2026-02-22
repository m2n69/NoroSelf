#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/m2n69/NoroSelf.git"
DEFAULT_VERSION="v0.1"
VERSION="${DEFAULT_VERSION}"

# -------------------------
# Argument parsing
# -------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-v)
      VERSION="${2:-}"
      [[ -z "${VERSION}" ]] && { echo "Error: --version requires a value"; exit 1; }
      shift 2
      ;;
    *)
      echo "Error: Unknown argument: $1"
      exit 1
      ;;
  esac
done

# -------------------------
# Root check
# -------------------------
if [[ "${EUID:-0}" -ne 0 ]]; then
  echo "Error: Please run as root (sudo -i)"
  exit 1
fi

echo "======================================"
echo "            NoroSelf Installer"
echo "======================================"
echo "Version: ${VERSION}"
echo

# -------------------------
# TTY-safe prompts
# -------------------------
tty_available() { [[ -r /dev/tty && -w /dev/tty ]]; }

prompt() {
  local msg="$1" out=""
  if tty_available; then
    read -r -p "${msg}" out < /dev/tty
  else
    read -r -p "${msg}" out
  fi
  printf "%s" "${out}"
}

prompt_secret() {
  local msg="$1" out=""
  if tty_available; then
    stty -echo < /dev/tty
    printf "%s" "${msg}" > /dev/tty
    read -r out < /dev/tty
    stty echo < /dev/tty
    printf "\n" > /dev/tty
  else
    read -rsp "${msg}" out
    echo
  fi
  printf "%s" "${out}"
}

# -------------------------
# Inputs
# -------------------------
SELF_NAME="$(prompt "Selfbot name: ")"
SELF_NAME="${SELF_NAME// /}"

PHONE_NUMBER="$(prompt "Phone number: ")"
PHONE_NUMBER="${PHONE_NUMBER// /}"

ADMIN_USER_ID="$(prompt "Admin user ID: ")"
API_ID="$(prompt "API ID: ")"
API_HASH="$(prompt "API Hash: ")"

BOTNAME="$(prompt "Helper bot username: ")"
BOTNAME="${BOTNAME//@/}"

BOT_TOKEN="$(prompt_secret "Bot token: ")"

BASE_DIR="/root"
APP_DIR="${BASE_DIR}/${SELF_NAME}"

echo
echo "[1/6] Installing dependencies..."
apt update -y
apt install -y git python3-venv python3-full

if [[ -d "${APP_DIR}" ]]; then
  echo "Error: Directory already exists -> ${APP_DIR}"
  exit 1
fi

echo "[2/6] Cloning repository..."
cd "${BASE_DIR}"
git clone --branch "${VERSION}" --depth 1 "${REPO_URL}" "${APP_DIR}"

cd "${APP_DIR}"

echo "[3/6] Creating virtual environment..."
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

echo "[4/6] Updating configuration..."
INFO_FILE="${APP_DIR}/lib/Information.py"

python3 - <<PY
import re, pathlib, sys

admin_user_id = "${ADMIN_USER_ID}"
api_id = "${API_ID}"
api_hash = "${API_HASH}"
botname = "${BOTNAME}"
bot_token = "${BOT_TOKEN}"
self_name = "${SELF_NAME}"

p = pathlib.Path("${INFO_FILE}")
s = p.read_text()

def must_sub(pattern, repl):
    global s
    s, n = re.subn(pattern, repl, s)
    if n == 0:
        sys.exit(f"Pattern not found: {pattern}")

must_sub(r"admin_user_id\s*=\s*\d+", f"admin_user_id = {admin_user_id}")
must_sub(r"api_id\s*=\s*\d+", f"api_id = {api_id}")
must_sub(r"api_hash\s*=\s*'[^']*'", f"api_hash = '{api_hash}'")
must_sub(r"helper_username\s*=\s*'[^']*'", f"helper_username = '{botname}'")
must_sub(r"bot_token\s*=\s*'[^']*'", f"bot_token = '{bot_token}'")
must_sub(r"TelegramClient\('([^']*)'", f"TelegramClient('{self_name}'")

p.write_text(s)
print("Configuration updated")
PY

# -------------------------
# LOGIN (STABLE METHOD)
# -------------------------
echo
echo "[5/6] Telegram Login"
echo "Launching main.py..."
echo "Complete login if required."
echo "After successful login press CTRL+C to continue."
echo

cd "${APP_DIR}"
source venv/bin/activate

python3 main.py || true

echo
echo "Checking session file..."

if [[ ! -f "${APP_DIR}/${SELF_NAME}.session" ]]; then
  echo "Error: Session file not found."
  echo "Login may have failed."
  exit 1
fi

echo "Login successful."

# -------------------------
# SYSTEMD
# -------------------------
echo
echo "[6/6] Creating systemd services..."

cat > "/etc/systemd/system/${SELF_NAME}-helper.service" <<EOF
[Unit]
Description=${SELF_NAME} Helper Service
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/venv/bin/python helper.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > "/etc/systemd/system/${SELF_NAME}-main.service" <<EOF
[Unit]
Description=${SELF_NAME} Main Service
After=${SELF_NAME}-helper.service
Requires=${SELF_NAME}-helper.service

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/venv/bin/python main.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SELF_NAME}-helper.service"
systemctl enable --now "${SELF_NAME}-main.service"

echo
echo "======================================"
echo "Installation Completed Successfully"
echo "======================================"
