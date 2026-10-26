# Linux Deployment — Simpro Schedules (Next 30 Days)

Runs `main.py` **daily at 23:00 Melbourne time** via a systemd timer. Each run replaces all rows in
`specialisedspdr_sp_readwrite.Simpro_Schedules_Next30Days` with job schedules from tomorrow to today + 30.
Logs go to **both** the systemd journal and a rotating file (`logs/schedule_next_30days.log`).

---

## 1. Prerequisites on the server

- Linux with systemd 235+ (Ubuntu 20.04+, Debian 11+, RHEL 8+)
- Python 3.10+ (`python3 --version`)
- `python3-venv` and `rsync` (`sudo apt install python3-venv rsync` on Debian/Ubuntu)
- **Microsoft ODBC Driver 18 for SQL Server** — needed by `pyodbc`. The deploy script stops if it's missing.
  Check with:
  ```bash
  odbcinst -q -d
  ```
  If `ODBC Driver 18 for SQL Server` isn't listed, install it following Microsoft's guide for your distro:
  https://learn.microsoft.com/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server
  (on Ubuntu/Debian it ends with `sudo ACCEPT_EULA=Y apt-get install -y msodbcsql18 unixodbc-dev`)
- The server's public IP must be allowed through the Azure SQL firewall.
- Root / sudo access

---

## 2. Copy the project to the server

From your machine (the folder name has spaces, so keep the quotes):

```bash
rsync -av --exclude='venv' --exclude='__pycache__' --exclude='logs' --exclude='.env' \
  "./schedule next 30days/" user@server:/tmp/schedule-next-30days/
```

---

## 3. Deploy

```bash
ssh user@server
cd /tmp/schedule-next-30days
sudo INSTALL_DIR=/opt/schedule-next-30days SERVICE_USER=$(whoami) \
  bash deploy/deploy.sh
```

What this does:
1. Checks the ODBC driver is installed
2. Copies code to `/opt/schedule-next-30days` (an existing `.env` there is kept)
3. Creates `venv/` and installs `requirements.txt`
4. Creates `logs/`
5. Installs `schedule-next-30days.service` and `.timer` into `/etc/systemd/system/`
6. Enables and starts the timer

Override env vars if needed:
- `INSTALL_DIR` — where the app lives. Default `/opt/schedule-next-30days`.
- `SERVICE_USER` — Linux user the service runs as. Default: the user invoking sudo.
- `PYTHON_BIN` — alternate Python. Default `python3`.

---

## 4. Create the `.env` (first deploy only)

```bash
cd /opt/schedule-next-30days
sudo -u <service user> cp .env.example .env
sudo -u <service user> nano .env    # fill in all values
chmod 600 .env
```

| Key | What |
|---|---|
| `SIMPRO_BASE_URL` | `https://specialisedplumbing.simprosuite.com` (with or without `/api`) |
| `SIMPRO_API_KEY` | Simpro bearer token |
| `SIMPRO_COMPANY_ID` | `2` |
| `SQL_SERVER_HOST` | Azure SQL server host |
| `SQL_SERVER_DB` | Database name |
| `SQL_SERVER_USER` | SQL login (needs DELETE + INSERT on the table) |
| `SQL_SERVER_PASSWORD` | SQL password |
| `LOG_DIR` | Optional. Default `./logs`. |

---

## 5. Verify

```bash
# Is the timer scheduled? NEXT should show 23:00 Melbourne (printed in the server's timezone)
systemctl list-timers schedule-next-30days.timer

# Force a run right now (don't wait for 23:00)
sudo systemctl start schedule-next-30days.service

# Was the most recent run successful?
systemctl status schedule-next-30days.service
```

A successful run ends with:
```
[INFO] DONE | replaced specialisedspdr_sp_readwrite.Simpro_Schedules_Next30Days (536 rows)
```

And in SQL:
```sql
SELECT COUNT(*) AS Rows, MIN([Date]) AS FirstDate, MAX([Date]) AS LastDate, MAX(LoadedAt) AS LoadedAt
FROM specialisedspdr_sp_readwrite.Simpro_Schedules_Next30Days;
```

---

## 6. View logs

**Live tail (systemd journal):**
```bash
journalctl -u schedule-next-30days.service -f
```

**Last run only:**
```bash
journalctl -u schedule-next-30days.service -n 200 --no-pager
```

**Errors across all past runs:**
```bash
journalctl -u schedule-next-30days.service -p err --since "7 days ago"
```

**Persistent file log** (rotated at 10 MB, 5 backups = ~50 MB max):
```bash
tail -f /opt/schedule-next-30days/logs/schedule_next_30days.log
```

---

## 7. Updating after code changes

Copy the updated code to `/tmp/schedule-next-30days` again (step 2), then re-run the deploy script.
It's safe to run repeatedly, and `.env` is kept:

```bash
sudo INSTALL_DIR=/opt/schedule-next-30days SERVICE_USER=$(whoami) \
  bash deploy/deploy.sh
```

---

## 8. Stop / disable

```bash
# Stop the timer (no more scheduled runs)
sudo systemctl disable --now schedule-next-30days.timer

# Fully remove
sudo rm /etc/systemd/system/schedule-next-30days.{service,timer}
sudo systemctl daemon-reload
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ERROR: 'ODBC Driver 18 for SQL Server' is not installed` | Install `msodbcsql18` (section 1), then re-run deploy. |
| `Can't open lib 'ODBC Driver 18 for SQL Server'` | Same as above — the driver is missing or broken. |
| `Login timeout expired` / `TCP Provider` error | Server IP not allowed in the Azure SQL firewall, or outbound port 1433 is blocked. |
| `Invalid object name ...Simpro_Schedules_Next30Days` | Table not created — run `create_tables.sql` in the database. |
| `Missing SIMPRO_API_KEY in .env` | `.env` not present or unreadable by the service user. Check `ls -la /opt/schedule-next-30days/.env`. |
| `/usr/bin/env: 'bash\r': No such file or directory` | Scripts got Windows line endings. Run `sed -i 's/\r$//' deploy/*.sh` and retry. |
| `Failed to start ... Permission denied` | `sudo chown -R <service user>:<service user> /opt/schedule-next-30days` |
| A run failed — is the table empty? | No. The delete + insert is one transaction, so on failure the previous day's data stays. |
