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
      if [[ -z "${VERSION}" ]]; then
        echo "Error: --version requires a value (e.g. --version v0.1)"
        exit 1
      fi
      shift 2
      ;;
    *)
      echo "Error: Unknown argument: $1"
      echo "Usage: bash <(curl -fsSL .../install.sh) --version v0.1"
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
# Inputs
# -------------------------
read -rp "Selfbot name (used for folder/session/systemd): " SELF_NAME
SELF_NAME="${SELF_NAME// /}"
if [[ -z "${SELF_NAME}" ]]; then
  echo "Error: Invalid selfbot name"
  exit 1
fi

read -rp "Phone number (international, e.g. +49123456789): " PHONE_NUMBER
PHONE_NUMBER="${PHONE_NUMBER// /}"
if [[ -z "${PHONE_NUMBER}" ]]; then
  echo "Error: Invalid phone number"
  exit 1
fi

read -rp "Admin user ID (numeric): " ADMIN_USER_ID
read -rp "API ID (numeric): " API_ID
read -rp "API Hash: " API_HASH

read -rp "Helper bot username (without @): " BOTNAME
BOTNAME="${BOTNAME//@/}"

read -rsp "Bot token: " BOT_TOKEN
echo

BASE_DIR="/root"
APP_DIR="${BASE_DIR}/${SELF_NAME}"

echo
echo "[1/6] Installing dependencies..."
apt update -y
apt install -y git python3-venv python3-full

# -------------------------
# Directory check
# -------------------------
if [[ -d "${APP_DIR}" ]]; then
  echo "Error: Directory already exists -> ${APP_DIR}"
  echo "If you want to reinstall, remove it first:"
  echo "  rm -rf ${APP_DIR}"
  exit 1
fi

# -------------------------
# Clone selected version (tag/branch)
# -------------------------
echo "[2/6] Cloning repository (version: ${VERSION})..."
cd "${BASE_DIR}"
git clone --branch "${VERSION}" --depth 1 "${REPO_URL}" "${APP_DIR}"

cd "${APP_DIR}"

# -------------------------
# Virtual environment
# -------------------------
echo "[3/6] Creating virtual environment and installing requirements..."
python3 -m venv venv
# shellcheck disable=SC1091
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# -------------------------
# Update configuration (safe substitution)
# -------------------------
echo "[4/6] Updating lib/Information.py..."
INFO_FILE="${APP_DIR}/lib/Information.py"

python3 - <<PY
import re, pathlib, sys

admin_user_id = "${ADMIN_USER_ID}".strip()
api_id = "${API_ID}".strip()
api_hash = "${API_HASH}".strip()
botname = "${BOTNAME}".strip()
bot_token = "${BOT_TOKEN}".strip()
self_name = "${SELF_NAME}".strip()

if not admin_user_id.isdigit():
    sys.exit("Error: Admin user ID must be numeric")
if not api_id.isdigit():
    sys.exit("Error: API ID must be numeric")
if not api_hash:
    sys.exit("Error: API Hash is empty")
if not botname:
    sys.exit("Error: Helper bot username is empty")
if not bot_token:
    sys.exit("Error: Bot token is empty")
if not self_name:
    sys.exit("Error: Self name is empty")

p = pathlib.Path("${INFO_FILE}")
s = p.read_text(encoding="utf-8")

def must_sub(pattern, repl, text):
    new, n = re.subn(pattern, repl, text, flags=re.MULTILINE)
    if n == 0:
        raise SystemExit(f"Pattern not found in Information.py: {pattern}")
    return new

s = must_sub(r"admin_user_id\s*=\s*\d+", f"admin_user_id = {admin_user_id}", s)
s = must_sub(r"api_id\s*=\s*\d+", f"api_id = {api_id}", s)
s = must_sub(r"api_hash\s*=\s*'[^']*'", f"api_hash = '{api_hash}'", s)
s = must_sub(r"helper_username\s*=\s*'[^']*'", f"helper_username = '{botname}'", s)
s = must_sub(r"bot_token\s*=\s*'[^']*'", f"bot_token = '{bot_token}'", s)

# Ensure Telethon session name matches SELF_NAME (TelegramClient('...', api_id, api_hash))
s = must_sub(
    r"TelegramClient\('([^']*)'\s*,\s*api_id\s*,\s*api_hash\)",
    f"TelegramClient('{self_name}', api_id, api_hash)",
    s
)

p.write_text(s, encoding="utf-8")
print("Configuration updated")
PY

# -------------------------
# Login + verify (2FA asked only if needed)
# -------------------------
echo
echo "[5/6] Creating and verifying Telegram session (interactive)..."
echo "You will be asked for the login code."

python3 - <<PY
import sys
from telethon import TelegramClient
from telethon.errors import SessionPasswordNeededError

api_id = int("${API_ID}")
api_hash = "${API_HASH}"
session_name = "${SELF_NAME}"
phone = "${PHONE_NUMBER}"

client = TelegramClient(session_name, api_id, api_hash)

def ask_code():
    return input("Login code: ").strip()

def ask_2fa():
    # no echo handling in pure python here; keep simple for now
    return input("2FA password: ").strip()

try:
    client.connect()

    if not client.is_user_authorized():
        client.send_code_request(phone)
        try:
            client.sign_in(phone=phone, code=ask_code())
        except SessionPasswordNeededError:
            client.sign_in(password=ask_2fa())

    me = client.get_me()
    if not me:
        print("Error: get_me() returned nothing. Login failed.", file=sys.stderr)
        sys.exit(1)

    uname = f"@{me.username}" if getattr(me, "username", None) else "(no username)"
    print(f"Login OK: id={me.id} {uname}")
finally:
    client.disconnect()
PY

if [[ ! -f "${APP_DIR}/${SELF_NAME}.session" ]]; then
  echo "Error: Session file not found: ${APP_DIR}/${SELF_NAME}.session"
  echo "Login may have failed."
  exit 1
fi

echo "Session file found: ${APP_DIR}/${SELF_NAME}.session"

# -------------------------
# Systemd services (helper + main)
# -------------------------
echo
echo "[6/6] Creating systemd services..."

HELPER_SERVICE="/etc/systemd/system/${SELF_NAME}-helper.service"
MAIN_SERVICE="/etc/systemd/system/${SELF_NAME}-main.service"

cat > "${HELPER_SERVICE}" <<EOF
[Unit]
Description=${SELF_NAME} Helper Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/venv/bin/python helper.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

cat > "${MAIN_SERVICE}" <<EOF
[Unit]
Description=${SELF_NAME} Main Service
After=network.target ${SELF_NAME}-helper.service
Requires=${SELF_NAME}-helper.service

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/venv/bin/python main.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

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
echo
echo "Service status:"
systemctl status "${SELF_NAME}-helper.service" --no-pager || true
echo "--------------------------------------"
systemctl status "${SELF_NAME}-main.service" --no-pager || true

echo
echo "Logs:"
echo "  journalctl -u ${SELF_NAME}-main.service -n 200 --no-pager"
echo "  journalctl -u ${SELF_NAME}-helper.service -n 200 --no-pager"
