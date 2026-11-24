
#!/usr/bin/env bash
set -euo pipefail

# -------------------------
# Root check
# -------------------------
if [[ "${EUID:-0}" -ne 0 ]]; then
    echo "Error: Please run as root."
    exit 1
fi

# -------------------------
# Select Bot
# -------------------------
read -r -p "Selfbot name: " SELF_NAME
SELF_NAME="${SELF_NAME// /}"

if [[ -z "${SELF_NAME}" ]]; then
    echo "Error: Selfbot name is required."
    exit 1
fi

BASE_DIR="/root"
APP_DIR="${BASE_DIR}/${SELF_NAME}"

if [[ ! -d "${APP_DIR}" ]]; then
    echo "Error: Directory not found: ${APP_DIR}"
    exit 1
fi

# -------------------------
# Virtual Environment
# -------------------------
if [[ ! -f "${APP_DIR}/venv/bin/activate" ]]; then
    echo "Error: Virtual environment not found."
    exit 1
fi

cd "${APP_DIR}"
source venv/bin/activate

# -------------------------
# Main Login
# -------------------------
echo
echo "Launching main.py..."
echo "Complete login if required."
echo "After successful login press CTRL+C to continue."
echo

python3 main.py || true

# -------------------------
# Check Session
# -------------------------
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
echo "Creating systemd services..."

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
