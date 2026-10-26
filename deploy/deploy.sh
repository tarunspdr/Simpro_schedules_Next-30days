#!/usr/bin/env bash
# Idempotent deployer for the Simpro schedules (next 30 days) load on a Linux server.
#
# Installs code + venv into INSTALL_DIR only. It does NOT touch crontab —
# add the cron line yourself (see DEPLOY.md), so other jobs on the server
# are never affected.
#
# Run with sudo (needed to write under /opt). Safe to re-run after code changes.
#
# Usage:
#   sudo INSTALL_DIR=/opt/Schedule_Next_30Days SERVICE_USER=xrdpuser bash deploy/deploy.sh
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/Schedule_Next_30Days}"
SERVICE_USER="${SERVICE_USER:-$(logname 2>/dev/null || echo root)}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 0. main.py connects with pyodbc + Microsoft's ODBC Driver 18 — fail early if missing
if ! odbcinst -q -d 2>/dev/null | grep -q "ODBC Driver 18 for SQL Server"; then
  echo "ERROR: 'ODBC Driver 18 for SQL Server' is not installed." >&2
  exit 1
fi

echo "==> Installing to $INSTALL_DIR (owner: $SERVICE_USER)"

# 1. Copy application files (preserves .env if it already exists)
mkdir -p "$INSTALL_DIR"
rsync -a --exclude='venv' --exclude='__pycache__' --exclude='logs' \
      --exclude='.env' --exclude='*.pyc' --exclude='.git' \
      "$REPO_DIR/" "$INSTALL_DIR/"

# 2. Build / refresh the virtualenv (project-local, system Python untouched)
if [[ ! -d "$INSTALL_DIR/venv" ]]; then
  echo "==> Creating venv"
  "$PYTHON_BIN" -m venv "$INSTALL_DIR/venv"
fi
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

# 3. Log directory
mkdir -p "$INSTALL_DIR/logs"

# 4. Ownership — only inside INSTALL_DIR
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
if [[ -f "$INSTALL_DIR/.env" ]]; then
  chmod 600 "$INSTALL_DIR/.env"
else
  echo "WARNING: $INSTALL_DIR/.env not found — create it before the first run (see DEPLOY.md)." >&2
fi

echo ""
echo "==> Done. Code is in $INSTALL_DIR"
echo ""
echo "Test run (as $SERVICE_USER):"
echo "  cd $INSTALL_DIR && venv/bin/python -m main"
echo ""
echo "Then add this line with 'crontab -e' (as $SERVICE_USER), if not already there:"
echo "  0 23 * * * cd $INSTALL_DIR && $INSTALL_DIR/venv/bin/python -m main >> $INSTALL_DIR/logs/cron.log 2>&1"
