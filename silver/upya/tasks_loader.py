# silver/upya/tasks_loader.py
# Chargement des tâches UPYA vers silver.upya_tasks
# Corrections : format date "21-Feb-2025 02:12:10", assignedTo string, assignedToLastName

import os
import time
import json
import logging
from datetime import datetime, timedelta, timezone

import requests
from requests.auth import HTTPBasicAuth
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

import psycopg2
from psycopg2.extras import execute_values
from dotenv import load_dotenv

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

API_URL = "https://data.upya.io/data/search/tasks"
HEADERS = {"Content-Type": "application/json", "Accept": "application/json"}


def parse_iso_any(date_str):
    if not date_str:
        return None
    for fmt in (
        "%Y-%m-%dT%H:%M:%S.%fZ",
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%d",
        "%d-%b-%Y %H:%M:%S",   # format UPYA tasks : "21-Feb-2025 02:12:10"
        "%d-%b-%Y",
    ):
        try:
            dt = datetime.strptime(date_str, fmt)
            return dt.replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def build_session(max_retries=3, backoff_factor=1.0):
    s = requests.Session()
    retry = Retry(
        total=max_retries,
        connect=max_retries,
        read=max_retries,
        status=max_retries,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=("GET", "POST"),
        backoff_factor=backoff_factor,
        raise_on_status=False,
    )
    adapter = HTTPAdapter(max_retries=retry)
    s.mount("https://", adapter)
    s.mount("http://", adapter)
    return s


def qident(schema, table):
    schema = schema or "public"
    return f'"{schema}"."{table}"'


def ensure_tasks_schema(cur, conn, schema, table):
    cur.execute("""
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = %s AND table_name = %s
        ORDER BY ordinal_position
    """, (schema, table))
    cols = {r[0] for r in cur.fetchall()}
    fq = qident(schema, table)

    if not cols:
        cur.execute(f"""
        CREATE SCHEMA IF NOT EXISTS "{schema}";
        CREATE TABLE {fq} (
            task_id                TEXT PRIMARY KEY,
            task_number            TEXT,
            title                  TEXT,
            priority               TEXT,
            instructions           TEXT,
            assigned_on            TIMESTAMPTZ,
            due_on                 TIMESTAMPTZ,
            completed_on           TIMESTAMPTZ,
            closed_on              TIMESTAMPTZ,
            assigned_to            TEXT,
            assigned_to_last_name  TEXT,
            contract_number        TEXT,
            client_number          TEXT,
            parent_ticket          TEXT,
            status                 TEXT,
            category               TEXT,
            sub_category           TEXT,
            updated_at_src         TIMESTAMPTZ,
            created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at_db          TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        """)
        conn.commit()
    else:
        # Ajouter assigned_to_last_name si absent
        if "assigned_to_last_name" not in cols:
            cur.execute(f'ALTER TABLE {fq} ADD COLUMN assigned_to_last_name TEXT;')
            conn.commit()

    cur.execute(f'CREATE INDEX IF NOT EXISTS idx_tasks_assigned_on ON {fq}(assigned_on);')
    cur.execute(f'CREATE INDEX IF NOT EXISTS idx_tasks_due_on ON {fq}(due_on);')
    cur.execute(f'CREATE INDEX IF NOT EXISTS idx_tasks_status ON {fq}(status);')
    cur.execute(f'CREATE INDEX IF NOT EXISTS idx_tasks_updated_src ON {fq}(updated_at_src);')
    cur.execute(f'CREATE INDEX IF NOT EXISTS idx_tasks_contract ON {fq}(contract_number);')
    cur.execute(f'CREATE INDEX IF NOT EXISTS idx_tasks_client ON {fq}(client_number);')
    conn.commit()


def get_watermark(cur, schema, table, default_days_back=365*5):
    try:
        cur.execute(f'SELECT MAX(updated_at_src) FROM {qident(schema, table)};')
        max_dt = cur.fetchone()[0]
        if max_dt:
            return (max_dt - timedelta(days=1)).date().isoformat()
        return (datetime.now(timezone.utc) - timedelta(days=default_days_back)).date().isoformat()
    except Exception as e:
        logger.warning(f"Watermark indisponible, fallback initial: {e}")
        return (datetime.now(timezone.utc) - timedelta(days=default_days_back)).date().isoformat()


def extract_task_fields(task):
    task_id       = task.get("taskId")
    task_number   = task.get("taskNumber")
    title         = task.get("title")
    priority      = task.get("priority")
    instructions  = task.get("instructions")

    assigned_on   = parse_iso_any(task.get("assignedOn"))
    due_on        = parse_iso_any(task.get("dueOn"))
    completed_on  = parse_iso_any(task.get("completedOn"))
    closed_on     = parse_iso_any(task.get("closedOn"))

    # assignedTo = string (agent number) dans l'API UPYA tasks
    assigned_to           = task.get("assignedTo")
    assigned_to_last_name = task.get("assignedToLastName")

    contract_number = task.get("contractNumber")
    client_number   = task.get("clientNumber")
    parent_ticket   = task.get("parentTicket")

    # status/category absents de l'API — NULL par défaut
    status       = task.get("status")
    category     = task.get("category")
    sub_category = task.get("subCategory")

    updated_at_src = parse_iso_any(task.get("updatedAt"))

    return (
        task_id, task_number, title, priority, instructions,
        assigned_on, due_on, completed_on, closed_on,
        assigned_to, assigned_to_last_name,
        contract_number, client_number,
        parent_ticket, status, category, sub_category,
        updated_at_src
    )


def main():
    try:
        load_dotenv()

        UPYA_USERNAME = os.getenv("UPYA_USERNAME")
        UPYA_PASSWORD = os.getenv("UPYA_PASSWORD")
        DB_HOST       = os.getenv("DB_HOST")
        DB_PORT       = int(os.getenv("DB_PORT") or 5432)
        DB_NAME       = os.getenv("DB_NAME")
        DB_USER       = os.getenv("DB_USER")
        DB_PASSWORD   = os.getenv("DB_PASSWORD")
        DB_SCHEMA     = os.getenv("DB_SCHEMA_TASKS") or "silver"
        TASKS_TABLE   = os.getenv("TASKS_TABLE") or "upya_tasks"

        missing = [k for k, v in {
            "UPYA_USERNAME": UPYA_USERNAME, "UPYA_PASSWORD": UPYA_PASSWORD,
            "DB_HOST": DB_HOST, "DB_PORT": DB_PORT,
            "DB_NAME": DB_NAME, "DB_USER": DB_USER, "DB_PASSWORD": DB_PASSWORD
        }.items() if not v]
        if missing:
            raise ValueError(f"Variables manquantes: {missing}")

        logger.info(f"Connexion PostgreSQL → {DB_HOST}:{DB_PORT}/{DB_NAME}")
        conn = psycopg2.connect(
            host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
            user=DB_USER, password=DB_PASSWORD,
            sslmode="require", connect_timeout=30
        )
        conn.autocommit = False
        cur = conn.cursor()

        ensure_tasks_schema(cur, conn, DB_SCHEMA, TASKS_TABLE)
        fq = qident(DB_SCHEMA, TASKS_TABLE)
        logger.info(f"Table prête : {fq}")

        session = build_session()
        auth    = HTTPBasicAuth(UPYA_USERNAME, UPYA_PASSWORD)
        watermark = get_watermark(cur, DB_SCHEMA, TASKS_TABLE)
        logger.info(f"Watermark : {watermark}")

        UPSERT_SQL = f"""
        INSERT INTO {fq} (
            task_id, task_number, title, priority, instructions,
            assigned_on, due_on, completed_on, closed_on,
            assigned_to, assigned_to_last_name,
            contract_number, client_number,
            parent_ticket, status, category, sub_category,
            updated_at_src
        ) VALUES %s
        ON CONFLICT (task_id) DO UPDATE SET
            task_number           = EXCLUDED.task_number,
            title                 = EXCLUDED.title,
            priority              = EXCLUDED.priority,
            instructions          = EXCLUDED.instructions,
            assigned_on           = EXCLUDED.assigned_on,
            due_on                = EXCLUDED.due_on,
            completed_on          = EXCLUDED.completed_on,
            closed_on             = EXCLUDED.closed_on,
            assigned_to           = EXCLUDED.assigned_to,
            assigned_to_last_name = EXCLUDED.assigned_to_last_name,
            contract_number       = EXCLUDED.contract_number,
            client_number         = EXCLUDED.client_number,
            parent_ticket         = EXCLUDED.parent_ticket,
            status                = EXCLUDED.status,
            category              = EXCLUDED.category,
            sub_category          = EXCLUDED.sub_category,
            updated_at_src        = EXCLUDED.updated_at_src,
            updated_at_db         = NOW();
        """

        page          = 1
        per_page      = 500
        total_upserts = 0
        error_pages   = 0

        while True:
            payload = {
                "query": {
                    "$or": [
                        {"updatedAt": {"$gte": watermark}},
                        {"assignedOn": {"$gte": watermark}}
                    ]
                },
                "paginate": True,
                "pageNumber": page,
                "nPerPage": per_page
            }

            try:
                resp = session.post(
                    API_URL, json=payload,
                    headers=HEADERS, auth=auth, timeout=60
                )
            except requests.RequestException as e:
                error_pages += 1
                logger.error(f"Erreur réseau page {page}: {e}")
                break

            if resp.status_code != 200:
                error_pages += 1
                logger.error(f"HTTP {resp.status_code} page {page}: {resp.text[:300]}")
                break

            data = (resp.json() or {}).get("data", [])
            if not data:
                logger.info("Fin de la pagination.")
                break

            rows = []
            for task in data:
                tid = task.get("taskId")
                if not tid:
                    continue
                rows.append(extract_task_fields(task))

            if rows:
                try:
                    execute_values(cur, UPSERT_SQL, rows, page_size=200)
                    conn.commit()
                    total_upserts += len(rows)
                    logger.info(f"Page {page} : {len(rows)} upserts (total {total_upserts})")
                except Exception as e:
                    conn.rollback()
                    logger.error(f"Erreur DB page {page} : {e}")

            page += 1
            time.sleep(0.7)

        logger.info("=" * 50)
        logger.info(f"✅ TASKS TERMINÉ")
        logger.info(f"   Upserts  : {total_upserts:,}")
        logger.info(f"   Erreurs  : {error_pages}")

        cur.execute(f"SELECT COUNT(*) FROM {fq}")
        logger.info(f"   Total BD : {cur.fetchone()[0]:,}")

        cur.execute(f"""
            SELECT MIN(assigned_on)::date, MAX(assigned_on)::date,
                   MIN(updated_at_src)::date, MAX(updated_at_src)::date
            FROM {fq}
        """)
        r = cur.fetchone()
        logger.info(f"   assigned_on  : {r[0]} → {r[1]}")
        logger.info(f"   updated_at   : {r[2]} → {r[3]}")
        logger.info("=" * 50)

    except Exception as e:
        logger.error(f"Erreur fatale: {e}", exc_info=True)
        return 1
    finally:
        try:
            if 'cur' in locals(): cur.close()
            if 'conn' in locals(): conn.close()
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())