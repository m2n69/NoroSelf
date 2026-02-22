#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/m2n69/NoroSelf.git"
DEFAULT_VERSION="v0.1"

VERSION="${DEFAULT_VERSION}"

# -------------------------
# Argument Parsing
# -------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-v)
      VERSION="$2"
      shift 2
      ;;
    *)
      echo "Error: Unknown argument $1"
      exit 1
      ;;
  esac
done

# -------------------------
# Root Check
# -------------------------
if [[ "${EUID:-0}" -ne 0 ]]; then
  echo "Error: Please run as root"
  exit 1
fi

echo "======================================"
echo "        NoroSelf Installer"
echo "======================================"
echo "Version: ${VERSION}"
echo

# -------------------------
# User Input
# -------------------------
read -rp "Selfbot name: " SELF_NAME
SELF_NAME="${SELF_NAME// /}"

if [[ -z "${SELF_NAME}" ]]; then
  echo "Error: Invalid selfbot name"
  exit 1
fi

read -rp "Admin user ID: " ADMIN_USER_ID
read -rp "API ID: " API_ID
read -rp "API Hash: " API_HASH
read -rp "Helper bot username: " BOTNAME
read -rp "Bot token: " BOT_TOKEN

BASE_DIR="/root"
APP_DIR="${BASE_DIR}/${SELF_NAME}"

echo
echo "[1/5] Installing dependencies..."

apt update -y
apt install -y git python3-venv python3-full

# -------------------------
# Directory Check
# -------------------------
if [[ -d "${APP_DIR}" ]]; then
  echo "Error: Directory already exists -> ${APP_DIR}"
  exit 1
fi

# -------------------------
# Clone Selected Version
# -------------------------
echo "[2/5] Cloning repository..."

cd "${BASE_DIR}"
git clone --branch "${VERSION}" --depth 1 "${REPO_URL}" "${APP_DIR}"

cd "${APP_DIR}"

# -------------------------
# Virtual Environment
# -------------------------
echo "[3/5] Creating virtual environment..."

python3 -m venv venv
source venv/bin/activate

pip install --upgrade pip
pip install -r requirements.txt

# -------------------------
# Update Configuration
# -------------------------
echo "[4/5] Updating configuration..."

INFO_FILE="${APP_DIR}/lib/Information.py"

python3 - <<PY
import re, pathlib

p = pathlib.Path("${INFO_FILE}")
s = p.read_text()

def replace(pattern, value):
    global s
    s = re.sub(pattern, value, s)

replace(r"admin_user_id\\s*=\\s*\\d+", "admin_user_id = ${ADMIN_USER_ID}")
replace(r"api_id\\s*=\\s*\\d+", "api_id = ${API_ID}")
replace(r"api_hash\\s*=\\s*'[^']*'", "api_hash = '${API_HASH}'")
replace(r"helper_username\\s*=\\s*'[^']*'", "helper_username = '${BOTNAME}'")
replace(r"bot_token\\s*=\\s*'[^']*'", "bot_token = '${BOT_TOKEN}'")
replace(r"TelegramClient\\('([^']*)'", "TelegramClient('${SELF_NAME}'")

p.write_text(s)
print("Configuration updated")
PY

# -------------------------
# Systemd Service
# -------------------------
echo "[5/5] Creating systemd service..."

SERVICE_FILE="/etc/systemd/system/${SELF_NAME}.service"

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=${SELF_NAME} Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/venv/bin/python main.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SELF_NAME}.service"

echo
echo "======================================"
echo "Installation Completed Successfully"
echo "======================================"
echo
echo "Service status:"
systemctl status "${SELF_NAME}.service" --no-pager
