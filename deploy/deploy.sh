#!/usr/bin/env bash
# Idempotent deployer for the Simpro schedules (next 30 days) load on a Linux server.
#
# Run as root (or with sudo). Re-run after code changes — it's safe to
# execute repeatedly.
#
# Usage:
#   sudo INSTALL_DIR=/opt/schedule-next-30days SERVICE_USER=ubuntu ./deploy.sh
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/schedule-next-30days}"
SERVICE_USER="${SERVICE_USER:-$(logname 2>/dev/null || echo root)}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
UNIT=schedule-next-30days

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 0. main.py connects with pyodbc + Microsoft's ODBC Driver 18 — fail early if missing
if ! odbcinst -q -d 2>/dev/null | grep -q "ODBC Driver 18 for SQL Server"; then
  echo "ERROR: 'ODBC Driver 18 for SQL Server' is not installed." >&2
  echo "Install msodbcsql18 + unixodbc first (see DEPLOY.md, section 1)." >&2
  exit 1
fi

echo "==> Installing to $INSTALL_DIR (owner: $SERVICE_USER)"

# 1. Copy application files (preserves .env if it already exists)
mkdir -p "$INSTALL_DIR"
rsync -a --exclude='venv' --exclude='__pycache__' --exclude='logs' \
      --exclude='.env' --exclude='*.pyc' \
      "$REPO_DIR/" "$INSTALL_DIR/"

# 2. Build / refresh the virtualenv
if [[ ! -d "$INSTALL_DIR/venv" ]]; then
  echo "==> Creating venv"
  "$PYTHON_BIN" -m venv "$INSTALL_DIR/venv"
fi
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

# 3. Ensure log directory exists and is writable
mkdir -p "$INSTALL_DIR/logs"

# 4. Ownership
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
# .env should be readable only by the service user
if [[ -f "$INSTALL_DIR/.env" ]]; then
  chmod 600 "$INSTALL_DIR/.env"
else
  echo "WARNING: $INSTALL_DIR/.env not found — create it before the first run (see DEPLOY.md)." >&2
fi

# 5. Install systemd units with the right user + paths baked in
echo "==> Installing systemd units"
sed -e "s|YOUR_LINUX_USER|$SERVICE_USER|g" \
    -e "s|/opt/schedule-next-30days|$INSTALL_DIR|g" \
    "$SCRIPT_DIR/$UNIT.service" \
    > "/etc/systemd/system/$UNIT.service"

cp "$SCRIPT_DIR/$UNIT.timer" "/etc/systemd/system/$UNIT.timer"

systemctl daemon-reload
systemctl enable --now "$UNIT.timer"

echo ""
echo "==> Done."
echo ""
echo "Check status:"
echo "  systemctl list-timers $UNIT.timer"
echo "  systemctl status $UNIT.service"
echo ""
echo "Watch live logs:"
echo "  journalctl -u $UNIT.service -f"
echo ""
echo "Run once now (manually):"
echo "  systemctl start $UNIT.service"
