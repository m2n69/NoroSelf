#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/m2n69/NoroSelf.git"
DEFAULT_VERSION="v0.1"
VERSION="${DEFAULT_VERSION}"

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

if [[ "${EUID:-0}" -ne 0 ]]; then
  echo "Error: Please run as root (sudo -i)"
  exit 1
fi

echo "======================================"
echo "            NoroSelf Installer"
echo "======================================"
echo "Version: ${VERSION}"
echo

read -rp "Selfbot name: " SELF_NAME
SELF_NAME="${SELF_NAME// /}"
[[ -z "${SELF_NAME}" ]] && { echo "Error: Invalid selfbot name"; exit 1; }

read -rp "Phone number (international format): " PHONE_NUMBER
PHONE_NUMBER="${PHONE_NUMBER// /}"
[[ -z "${PHONE_NUMBER}" ]] && { echo "Error: Invalid phone number"; exit 1; }

read -rp "Admin user ID: " ADMIN_USER_ID
read -rp "API ID: " API_ID
read -rp "API Hash: " API_HASH

read -rp "Helper bot username: " BOTNAME
BOTNAME="${BOTNAME//@/}"

read -rsp "Bot token: " BOT_TOKEN
echo

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
# shellcheck disable=SC1091
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

echo "[4/6] Updating configuration..."
INFO_FILE="${APP_DIR}/lib/Information.py"

python3 - <<PY
import re, pathlib, sys

admin_user_id = "${ADMIN_USER_ID}".strip()
api_id = "${API_ID}".strip()
api_hash = "${API_HASH}".strip()
botname = "${BOTNAME}".strip()
bot_token = "${BOT_TOKEN}".strip()
self_name = "${SELF_NAME}".strip()

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

echo
echo "[5/6] Creating Telegram session..."
echo "A login code was sent to your Telegram app/SMS."
echo "Please enter it below."

# Read from /dev/tty to avoid EOFError in non-standard stdin situations
if [[ ! -r /dev/tty ]]; then
  echo "Error: /dev/tty not available. Run this installer in a real SSH terminal."
  exit 1
fi

read -r -p "Login code: " LOGIN_CODE < /dev/tty

export NS_API_ID="${API_ID}"
export NS_API_HASH="${API_HASH}"
export NS_SESSION_NAME="${SELF_NAME}"
export NS_PHONE="${PHONE_NUMBER}"
export NS_LOGIN_CODE="${LOGIN_CODE}"

python3 - <<'PY'
import asyncio, os, sys
from telethon import TelegramClient
from telethon.errors import SessionPasswordNeededError, PhoneCodeInvalidError, PhoneCodeExpiredError

api_id = int(os.environ["NS_API_ID"])
api_hash = os.environ["NS_API_HASH"]
session_name = os.environ["NS_SESSION_NAME"]
phone = os.environ["NS_PHONE"]
code = os.environ["NS_LOGIN_CODE"]

async def main():
    client = TelegramClient(session_name, api_id, api_hash)
    await client.connect()

    if not await client.is_user_authorized():
        await client.send_code_request(phone)
        try:
            await client.sign_in(phone=phone, code=code)
        except SessionPasswordNeededError:
            # Ask 2FA password via /dev/tty (no echo)
            print("2FA password required.")
            # read password safely from tty
            import subprocess
            pwd = subprocess.check_output(["bash", "-lc", "read -s -p '2FA password: ' p < /dev/tty; echo; echo \"$p\""], text=True).strip()
            await client.sign_in(password=pwd)
        except (PhoneCodeInvalidError, PhoneCodeExpiredError) as e:
            print(f"Error: {type(e).__name__}. Please re-run installer and enter the correct/valid code.", file=sys.stderr)
            await client.disconnect()
            sys.exit(1)

    me = await client.get_me()
    if not me:
        print("Error: Login failed (get_me returned nothing).", file=sys.stderr)
        await client.disconnect()
        sys.exit(1)

    uname = f"@{me.username}" if me.username else "(no username)"
    print(f"Login OK -> id={me.id} {uname}")

    await client.disconnect()

asyncio.run(main())
PY

if [[ ! -f "${APP_DIR}/${SELF_NAME}.session" ]]; then
  echo "Error: Session file not found after login."
  exit 1
fi
echo "Session created: ${APP_DIR}/${SELF_NAME}.session"

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
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

cat > "/etc/systemd/system/${SELF_NAME}-main.service" <<EOF
[Unit]
Description=${SELF_NAME} Main Service
After=network.target ${SELF_NAME}-helper.service
Requires=${SELF_NAME}-helper.service

[Service]
Type=simple
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
echo "Service status:"
systemctl status "${SELF_NAME}-main.service" --no-pager || true
