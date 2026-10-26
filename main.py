# ================================================================
# Simpro job schedules: tomorrow → today+30, loaded into SQL Server.
#
#   GET /api/v1.0/companies/{companyID}/schedules/
#       ?Type=job&Date=between(<today+1>,<today+30>)&page=N&pageSize=250
#
# Every run fully replaces the contents of
# specialisedspdr_sp_readwrite.Simpro_Schedules_Next30Days
# (one row per schedule, see create_tables.sql). The delete + insert runs
# in one transaction, so if anything fails the table keeps the previous
# day's data.
#
# Deployed on Linux via cron, daily at 23:00 Melbourne (see DEPLOY.md).
# ================================================================
import os
import sys
import time
import logging
from datetime import date, datetime, time as dtime, timedelta
from logging.handlers import RotatingFileHandler
from pathlib import Path
from zoneinfo import ZoneInfo

import pyodbc
import requests
from dotenv import load_dotenv

HERE = Path(__file__).resolve().parent
load_dotenv(HERE / ".env")

MELBOURNE = ZoneInfo("Australia/Melbourne")
DAYS_AHEAD = 30
PAGE_SIZE = 250
RETRIES = 5
COLUMNS = "ID,Type,Reference,TotalHours,Staff,Date,Blocks"

SCHEDULES_TABLE = "specialisedspdr_sp_readwrite.Simpro_Schedules_Next30Days"

logger = logging.getLogger("schedule_next_30days")


def _setup_logging() -> None:
    """
    Rotating file logging, plus console when run by hand in a terminal.
    Under cron stdout is redirected to logs/cron.log, so console output is
    skipped there to avoid logging everything twice into an unrotated file.
    LOG_DIR env var overrides the default ./logs directory.
    """
    log_dir = Path(os.getenv("LOG_DIR", HERE / "logs"))
    log_dir.mkdir(parents=True, exist_ok=True)

    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    root.handlers.clear()

    if sys.stdout.isatty():
        console = logging.StreamHandler(sys.stdout)
        console.setFormatter(fmt)
        root.addHandler(console)

    # 10 MB per file, keep 5 — ~50 MB max
    file_h = RotatingFileHandler(
        log_dir / "schedule_next_30days.log",
        maxBytes=10 * 1024 * 1024, backupCount=5, encoding="utf-8",
    )
    file_h.setFormatter(fmt)
    root.addHandler(file_h)


def _env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        logger.error("Missing %s in .env", name)
        sys.exit(1)
    return value


def _base_url() -> str:
    # Accept either https://x.simprosuite.com or https://x.simprosuite.com/api
    url = _env("SIMPRO_BASE_URL").rstrip("/")
    return url if url.endswith("/api") else f"{url}/api"


def _int(value) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _time(value: str | None) -> dtime | None:
    return dtime.fromisoformat(value) if value else None


def _get(session: requests.Session, url: str, params: dict) -> requests.Response:
    for attempt in range(1, RETRIES + 1):
        r = session.get(url, params=params, timeout=60)
        if r.status_code == 429 or r.status_code >= 500:
            wait = int(r.headers.get("Retry-After", 2 ** attempt))
            logger.warning("%s from Simpro, retrying in %ss (%d/%d)", r.status_code, wait, attempt, RETRIES)
            time.sleep(wait)
            continue
        r.raise_for_status()
        return r
    r.raise_for_status()
    return r


def fetch_schedules(date_from: date, date_to: date) -> list[dict]:
    url = f"{_base_url()}/v1.0/companies/{_env('SIMPRO_COMPANY_ID')}/schedules/"
    session = requests.Session()
    session.headers.update({
        "Authorization": f"Bearer {_env('SIMPRO_API_KEY')}",
        "Content-Type":  "application/json",
    })

    schedules: list[dict] = []
    page = 1
    while True:
        params = {
            "page":     page,
            "pageSize": PAGE_SIZE,
            "Type":     "job",
            "Date":     f"between({date_from.isoformat()},{date_to.isoformat()})",
            "columns":  COLUMNS,
            "orderby":  "Date",
        }
        r = _get(session, url, params)
        batch = r.json()
        schedules.extend(batch)

        total_pages = int(r.headers.get("Result-Pages", 1) or 1)
        logger.info("page %d/%d: %d schedules", page, total_pages, len(batch))
        if page >= total_pages or not batch:
            break
        page += 1
    return schedules


def to_rows(schedules: list[dict], loaded_at: datetime) -> list[dict]:
    rows = []
    for s in schedules:
        staff = s.get("Staff") or {}
        reference = s.get("Reference") or ""
        # Job schedule references look like "<JobID>-<CostCenterID>"
        job_id, _, cost_center_id = reference.partition("-")
        # Blocks are only used to get the schedule's overall start/end time
        blocks = s.get("Blocks") or []
        starts = [_time(b.get("StartTime")) for b in blocks if b.get("StartTime")]
        ends = [_time(b.get("EndTime")) for b in blocks if b.get("EndTime")]
        rows.append({
            "ScheduleID":   s.get("ID"),
            "Date":         date.fromisoformat(s["Date"]),
            "Type":         s.get("Type"),
            "Reference":    reference,
            "JobID":        _int(job_id),
            "CostCenterID": _int(cost_center_id),
            "StaffID":      staff.get("ID"),
            "StaffName":    staff.get("Name"),
            "StaffType":    staff.get("Type"),
            "StartTime":    min(starts, default=None),
            "EndTime":      max(ends, default=None),
            "TotalHours":   s.get("TotalHours"),
            "LoadedAt":     loaded_at,
        })
    return rows


def _sql_connection() -> pyodbc.Connection:
    conn_str = (
        "DRIVER={ODBC Driver 18 for SQL Server};"
        f"SERVER=tcp:{_env('SQL_SERVER_HOST')},1433;"
        f"DATABASE={_env('SQL_SERVER_DB')};"
        f"UID={_env('SQL_SERVER_USER')};"
        f"PWD={_env('SQL_SERVER_PASSWORD')};"
        "Encrypt=yes;"
        "TrustServerCertificate=yes;"
        "Connection Timeout=30;"
    )
    return pyodbc.connect(conn_str, autocommit=False)


def _replace_table(cur: pyodbc.Cursor, table: str, rows: list[dict]) -> None:
    cur.execute(f"DELETE FROM {table}")
    if not rows:
        return
    cols = list(rows[0])
    sql = (
        f"INSERT INTO {table} ({', '.join(f'[{c}]' for c in cols)}) "
        f"VALUES ({', '.join('?' * len(cols))})"
    )
    cur.executemany(sql, [tuple(r[c] for c in cols) for r in rows])


def write_sql(rows: list[dict]) -> None:
    conn = _sql_connection()
    try:
        cur = conn.cursor()
        cur.fast_executemany = True
        _replace_table(cur, SCHEDULES_TABLE, rows)
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def main() -> None:
    # Mirrors SQL: sc.[Date] BETWEEN GETDATE() AND DATEADD(DAY, 30, GETDATE())
    # GETDATE() includes the time, so today's date-only rows fall before it → start tomorrow.
    # "Today" is Melbourne's date regardless of the server's timezone.
    now = datetime.now(MELBOURNE)
    today = now.date()
    date_from = today + timedelta(days=1)
    date_to = today + timedelta(days=DAYS_AHEAD)
    logger.info("START | fetching job schedules %s to %s", date_from, date_to)

    schedules = fetch_schedules(date_from, date_to)
    rows = to_rows(schedules, now.replace(tzinfo=None, microsecond=0))

    write_sql(rows)
    logger.info("DONE | replaced %s (%d rows)", SCHEDULES_TABLE, len(rows))


if __name__ == "__main__":
    _setup_logging()
    try:
        main()
    except Exception:
        # Non-zero exit so systemd marks the run as failed
        logger.exception("FAILED | table left unchanged")
        sys.exit(1)
