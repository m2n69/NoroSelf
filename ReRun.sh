
#!/usr/bin/env bash
set -Eeuo pipefail

# =====================================
# NoroSelf Installation Recovery
# =====================================

BASE_DIR="/root"

# -------------------------
# Root check
# -------------------------
if [[ "${EUID:-0}" -ne 0 ]]; then
    echo "Error: Please run as root."
    exit 1
fi

echo "======================================"
echo "       NoroSelf Installation Recovery"
echo "======================================"
echo

# -------------------------
# Select Bot
# -------------------------
read -r -p "Selfbot name: " SELF_NAME
SELF_NAME="${SELF_NAME// /}"

if [[ -z "${SELF_NAME}" ]]; then
    echo "Error: Selfbot name cannot be empty."
    exit 1
fi

APP_DIR="${BASE_DIR}/${SELF_NAME}"

if [[ ! -d "${APP_DIR}" ]]; then
    echo "Error: Bot directory not found: ${APP_DIR}"
    exit 1
fi

# -------------------------
# Check Required Files
# -------------------------
echo "[1/5] Checking installation files..."

for FILE in \
    "${APP_DIR}/venv/bin/python" \
    "${APP_DIR}/main.py" \
    "${APP_DIR}/helper.py" \
    "${APP_DIR}/lib/Information.py"
do
    if [[ ! -f "${FILE}" ]]; then
        echo "Error: Required file not found: ${FILE}"
        exit 1
    fi
done

PYTHON="${APP_DIR}/venv/bin/python"
SESSION_FILE="${APP_DIR}/${SELF_NAME}.session"

# -------------------------
# Telegram Login
# -------------------------
echo
echo "[2/5] Checking Telegram session..."

if [[ ! -f "${SESSION_FILE}" ]]; then

    echo "Session not found."
    echo "Starting Telegram login..."
    echo "Complete login if required."
    echo "Press CTRL+C after login finishes."
    echo

    cd "${APP_DIR}"

    set +e
    "${PYTHON}" main.py
    LOGIN_STATUS=$?
    set -e

    if [[ ! -f "${SESSION_FILE}" ]]; then
        echo "Error: Telegram session was not created."
        echo "Login process exit code: ${LOGIN_STATUS}"
        exit 1
    fi

    echo "Session file created."

else
    echo "Telegram session already exists."
    echo "Skipping login."
fi

# -------------------------
# Create Systemd Services
# -------------------------
echo
echo "[3/5] Creating systemd services..."

HELPER_SERVICE="${SELF_NAME}-helper.service"
MAIN_SERVICE="${SELF_NAME}-main.service"

cat > "/etc/systemd/system/${HELPER_SERVICE}" <<EOF
[Unit]
Description=${SELF_NAME} Helper Service
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=${PYTHON} helper.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > "/etc/systemd/system/${MAIN_SERVICE}" <<EOF
[Unit]
Description=${SELF_NAME} Main Service
After=${HELPER_SERVICE}
Requires=${HELPER_SERVICE}

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=${PYTHON} main.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# -------------------------
# Reload Systemd
# -------------------------
echo
echo "[4/5] Reloading systemd..."

systemctl daemon-reload

# -------------------------
# Enable and Start Services
# -------------------------
echo
echo "[5/5] Enabling and starting services..."

systemctl enable --now "${HELPER_SERVICE}"
systemctl enable --now "${MAIN_SERVICE}"

echo
echo "======================================"
echo " Recovery Completed Successfully"
echo "======================================"

echo
echo "Helper Service:"
systemctl status "${HELPER_SERVICE}" --no-pager || true

echo
echo "Main Service:"
systemctl status "${MAIN_SERVICE}" --no-pager || true

echo
echo "NoroSelf recovery finished."
