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

# 2. Log directory + ownership — only inside INSTALL_DIR
mkdir -p "$INSTALL_DIR/logs"
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# 3. Build / refresh the virtualenv as SERVICE_USER (project-local, system Python untouched).
#    Try stdlib venv first; fall back to the user's own virtualenv (e.g. in ~/.local)
#    on servers where python3-venv / ensurepip isn't available.
as_user() { sudo -u "$SERVICE_USER" -H "$@"; }

if [[ ! -x "$INSTALL_DIR/venv/bin/pip" ]]; then
  echo "==> Creating venv"
  rm -rf "$INSTALL_DIR/venv"   # clear any half-created venv from a failed attempt
  if ! as_user "$PYTHON_BIN" -m venv "$INSTALL_DIR/venv" 2>/dev/null; then
    echo "==> python3 -m venv unavailable, using virtualenv"
    rm -rf "$INSTALL_DIR/venv"
    as_user "$PYTHON_BIN" -m virtualenv "$INSTALL_DIR/venv"
  fi
fi
as_user "$INSTALL_DIR/venv/bin/pip" install --upgrade pip
as_user "$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

# 4. Lock down .env
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
