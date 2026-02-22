#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/m2n69/NoroSelf.git"
DEFAULT_VERSION="v0.1"
VERSION="${DEFAULT_VERSION}"

# -------------------------
# Helpers (TTY-safe prompts)
# -------------------------
tty_available() {
  [[ -r /dev/tty && -w /dev/tty ]]
}

prompt() {
  local msg="$1"
  local out=""
  if tty_available; then
    read -r -p "${msg}" out < /dev/tty
  else
    read -r -p "${msg}" out
  fi
  printf "%s" "${out}"
}

prompt_secret() {
  local msg="$1"
  local out=""
  if tty_available; then
    # Disable echo for password-like input
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
# Argument parsing
# -------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-v)
      VERSION="${2:-}"
      [[ -z "${VERSION}" ]] && { echo "Error: --version requires a value (e.g. --version v0.1)"; exit 1; }
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
SELF_NAME="$(prompt "Selfbot name (folder/session/systemd): ")"
SELF_NAME="${SELF_NAME// /}"
[[ -z "${SELF_NAME}" ]] && { echo "Error: Invalid selfbot name"; exit 1; }

PHONE_NUMBER="$(prompt "Phone number (international, e.g. +49123456789): ")"
PHONE_NUMBER="${PHONE_NUMBER// /}"
[[ -z "${PHONE_NUMBER}" ]] && { echo "Error: Invalid phone number"; exit 1; }

ADMIN_USER_ID="$(prompt "Admin user ID (numeric): ")"
API_ID="$(prompt "API ID (numeric): ")"
API_HASH="$(prompt "API Hash: ")"

BOTNAME="$(prompt "Helper bot username (without @): ")"
BOTNAME="${BOTNAME//@/}"

BOT_TOKEN="$(prompt_secret "Bot token: ")"
[[ -z "${BOT_TOKEN}" ]] && { echo "Error: Bot token is empty"; exit 1; }

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
# Clone selected version
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

s = must_sub(r"admin_user_id\\s*=\\s*\\d+", f"admin_user_id = {admin_user_id}", s)
s = must_sub(r"api_id\\s*=\\s*\\d+", f"api_id = {api_id}", s)
s = must_sub(r"api_hash\\s*=\\s*'[^']*'", f"api_hash = '{api_hash}'", s)
s = must_sub(r"helper_username\\s*=\\s*'[^']*'", f"helper_username = '{botname}'", s)
s = must_sub(r"bot_token\\s*=\\s*'[^']*'", f"bot_token = '{bot_token}'", s)

# Ensure Telethon session name matches SELF_NAME
s = must_sub(
    r"TelegramClient\\('([^']*)'\\s*,\\s*api_id\\s*,\\s*api_hash\\)",
    f"TelegramClient('{self_name}', api_id, api_hash)",
    s
)

p.write_text(s, encoding="utf-8")
print("Configuration updated")
PY

# -------------------------
# Login + verify (async + retry + tty-safe)
# -------------------------
echo
echo "[5/6] Creating and verifying Telegram session..."
echo "A login code was sent to your Telegram app/SMS."
echo "If you enter a wrong/expired code, you can retry without restarting."

export NS_API_ID="${API_ID}"
export NS_API_HASH="${API_HASH}"
export NS_SESSION_NAME="${SELF_NAME}"
export NS_PHONE="${PHONE_NUMBER}"

python3 - <<'PY'
import asyncio, os, sys
from telethon import TelegramClient
from telethon.errors import (
    SessionPasswordNeededError,
    PhoneCodeInvalidError,
    PhoneCodeExpiredError,
)

def tty_open():
    # Always read/write prompts via /dev/tty to avoid stdin EOF issues
    try:
        return open("/dev/tty", "r+", encoding="utf-8", buffering=1)
    except Exception:
        return None

def tty_input(prompt: str) -> str:
    tty = tty_open()
    if tty:
        tty.write(prompt)
        tty.flush()
        line = tty.readline()
        if not line:
            raise EOFError("EOF from /dev/tty")
        return line.strip()
    # fallback
    return input(prompt).strip()

def tty_getpass(prompt: str) -> str:
    import getpass
    tty = tty_open()
    if tty:
        # getpass supports stream; this keeps it hidden
        return getpass.getpass(prompt, stream=tty).strip()
    return getpass.getpass(prompt).strip()

api_id = int(os.environ["NS_API_ID"])
api_hash = os.environ["NS_API_HASH"]
session_name = os.environ["NS_SESSION_NAME"]
phone = os.environ["NS_PHONE"]

async def main():
    client = TelegramClient(session_name, api_id, api_hash)
    await client.connect()

    if not await client.is_user_authorized():
        await client.send_code_request(phone)

        while True:
            try:
                code = tty_input("Login code: ")
                await client.sign_in(phone=phone, code=code)
                break

            except PhoneCodeInvalidError:
                # keep retrying
                print("Invalid code. Please try again.", file=sys.stderr)

            except PhoneCodeExpiredError:
                print("Code expired. Sending a new code...", file=sys.stderr)
                await client.send_code_request(phone)

            except SessionPasswordNeededError:
                # 2FA required
                pwd = tty_getpass("2FA password: ")
                await client.sign_in(password=pwd)
                break

    me = await client.get_me()
    if not me:
        print("Error: Login failed (get_me returned nothing).", file=sys.stderr)
        await client.disconnect()
        sys.exit(1)

    uname = f"@{me.username}" if getattr(me, "username", None) else "(no username)"
    print(f"Login OK -> id={me.id} {uname}")

    await client.disconnect()

asyncio.run(main())
PY

if [[ ! -f "${APP_DIR}/${SELF_NAME}.session" ]]; then
  echo "Error: Session file not found after login -> ${APP_DIR}/${SELF_NAME}.session"
  exit 1
fi

echo "Session created: ${APP_DIR}/${SELF_NAME}.session"

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
echo "Logs:"
echo "  journalctl -u ${SELF_NAME}-main.service -n 200 --no-pager"
echo "  journalctl -u ${SELF_NAME}-helper.service -n 200 --no-pager"
