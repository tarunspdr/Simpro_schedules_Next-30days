# Linux Deployment — Simpro Schedules (Next 30 Days)

Runs `main.py` **daily at 23:00 Melbourne time** via **cron**, the same way as the other jobs on the server.
Each run replaces all rows in `specialisedspdr_sp_readwrite.Simpro_Schedules_Next30Days` with job schedules
from tomorrow to today + 30.

Logs:
- `logs/schedule_next_30days.log` — every run (rotated at 10 MB, 5 backups = ~50 MB max)
- `logs/cron.log` — only output that happens before logging starts (e.g. a missing package)

`deploy/deploy.sh` only writes inside the install folder. It never edits crontab, systemd, or system Python.

---

## 1. Prerequisites on the server

- Python 3.10+ (`python3 --version`)
- `rsync`, `git`
- Either `python3-venv`, or `virtualenv` installed for the service user (`python3 -m virtualenv --version`).
  This server uses the latter (virtualenv in `~xrdpuser/.local`); `deploy.sh` falls back to it automatically.
- **Microsoft ODBC Driver 18 for SQL Server** (`odbcinst -q -d` should list it)
- Server timezone must be Melbourne or Sydney (same clock), because cron uses the server's timezone:
  ```bash
  timedatectl | grep "Time zone"
  ```
- The server's public IP must be allowed through the Azure SQL firewall.

---

## 2. Get the code and install

```bash
git clone https://github.com/tarunspdr/Simpro_schedules_Next-30days.git /tmp/Schedule_Next_30Days
cd /tmp/Schedule_Next_30Days
sudo INSTALL_DIR=/opt/Schedule_Next_30Days SERVICE_USER=xrdpuser bash deploy/deploy.sh
```

What this does (all inside `/opt/Schedule_Next_30Days`):
1. Checks the ODBC driver is installed
2. Copies the code (an existing `.env` there is kept)
3. Creates `venv/` and installs `requirements.txt`
4. Creates `logs/` and sets ownership to `SERVICE_USER`

---

## 3. Create the `.env` (first deploy only)

```bash
cd /opt/Schedule_Next_30Days
cp .env.example .env
nano .env        # fill in all values, Ctrl+O Enter to save, Ctrl+X to exit
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

## 4. Test run

```bash
cd /opt/Schedule_Next_30Days && venv/bin/python -m main
```

It should end with:
```
[INFO] DONE | replaced specialisedspdr_sp_readwrite.Simpro_Schedules_Next30Days (536 rows)
```

---

## 5. Add the cron job

```bash
crontab -e
```

Add this block at the bottom (don't change any other lines), then save and exit:

```
# ================================
# Schedule_Next_30Days (daily 11 PM Melbourne)
# ================================
0 23 * * * cd /opt/Schedule_Next_30Days && /opt/Schedule_Next_30Days/venv/bin/python -m main >> /opt/Schedule_Next_30Days/logs/cron.log 2>&1
```

Check it was saved:
```bash
crontab -l | grep Schedule_Next_30Days
```

---

## 6. View logs

```bash
# Last run
tail -n 50 /opt/Schedule_Next_30Days/logs/schedule_next_30days.log

# Anything cron itself captured (should normally be empty)
tail -n 50 /opt/Schedule_Next_30Days/logs/cron.log
```

And in SQL:
```sql
SELECT COUNT(*) AS Rows, MIN([Date]) AS FirstDate, MAX([Date]) AS LastDate, MAX(LoadedAt) AS LoadedAt
FROM specialisedspdr_sp_readwrite.Simpro_Schedules_Next30Days;
```

---

## 7. Updating after code changes

```bash
cd /tmp/Schedule_Next_30Days && git pull
sudo INSTALL_DIR=/opt/Schedule_Next_30Days SERVICE_USER=xrdpuser bash deploy/deploy.sh
```

`.env`, `logs/` and the cron line are kept.

---

## 8. Stop

Remove the `Schedule_Next_30Days` block with `crontab -e`.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ERROR: 'ODBC Driver 18 for SQL Server' is not installed` | Install `msodbcsql18`, then re-run deploy. |
| `No module named virtualenv` | Neither venv nor virtualenv available for the service user. Install it as that user: `python3 -m pip install --user virtualenv`. Don't force `apt install python3-venv` on this server — its apt sources don't match the OS. |
| `Login timeout expired` / `TCP Provider` error | Server IP not allowed in the Azure SQL firewall, or outbound port 1433 is blocked. |
| `Invalid object name ...Simpro_Schedules_Next30Days` | Table not created — run `create_tables.sql` in the database. |
| `Missing SIMPRO_API_KEY in .env` | `.env` missing or unreadable. Check `ls -la /opt/Schedule_Next_30Days/.env`. |
| `/usr/bin/env: 'bash\r': No such file or directory` | Scripts got Windows line endings. Run `sed -i 's/\r$//' deploy/*.sh` and retry. |
| Cron didn't run | `grep CRON /var/log/syslog | tail` to see if cron fired; check `logs/cron.log`. |
| A run failed — is the table empty? | No. The delete + insert is one transaction, so on failure the previous day's data stays. |
