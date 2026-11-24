
#!/usr/bin/env bash
set -euo pipefail

# -------------------------
# Root check
# -------------------------
if [[ "${EUID:-0}" -ne 0 ]]; then
  echo "Error: Please run as root (sudo -i)"
  exit 1
fi

# -------------------------
# Select Bot
# -------------------------
read -r -p "Selfbot name: " SELF_NAME
SELF_NAME="${SELF_NAME// /}"

BASE_DIR="/root"
APP_DIR="${BASE_DIR}/${SELF_NAME}"

if [[ ! -d "${APP_DIR}" ]]; then
  echo "Error: Directory not found -> ${APP_DIR}"
  exit 1
fi

# -------------------------
# LOGIN (QR METHOD)
# -------------------------
echo
echo "[1/2] Telegram QR Login"
echo "Launching main_qr.py..."
echo "Scan the QR code using Telegram."
echo "After successful login press CTRL+C to continue."
echo

cd "${APP_DIR}"
source venv/bin/activate

pip install qrcode

python3 main_qr.py || true

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
echo "[2/2] Creating systemd services..."

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
echo "Recovery Completed Successfully"
echo "======================================"
