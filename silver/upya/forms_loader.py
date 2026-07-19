# forms.py — version robuste & idempotente
import os
import time
import json
import logging
import hashlib
from datetime import datetime, timedelta, timezone

import requests
from requests.auth import HTTPBasicAuth
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

import psycopg2
from psycopg2.extras import execute_values
from dotenv import load_dotenv


# --- Logging ---
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


API_URL = "https://data.upya.io/data/search/forms"
HEADERS = {"Content-Type": "application/json", "Accept": "application/json"}


def parse_iso_any(date_str):
    """Parse ISO -> tz-aware UTC datetime. Gère %fZ, Z, YYYY-MM-DD."""
    if not date_str:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d"):
        try:
            return datetime.strptime(date_str, fmt).replace(tzinfo=timezone.utc)
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


def ensure_forms_table(cur, conn, schema, table):
    fq = qident(schema, table)

    cur.execute("""
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = %s AND table_name = %s
        LIMIT 1
    """, (schema, table))
    exists = cur.fetchone() is not None

    if not exists:
        cur.execute(f"""
            CREATE SCHEMA IF NOT EXISTS "{schema}";
            CREATE TABLE {fq} (
                form_id            TEXT PRIMARY KEY,         -- identifiant natif si présent, sinon hash fallback
                form_number        TEXT,
                name               TEXT,
                status             TEXT,
                score              NUMERIC,
                client_number      TEXT,
                contract_number    TEXT,
                agent_number       TEXT,
                origin             TEXT,
                created_at_src     TIMESTAMPTZ,
                submitted_on       TIMESTAMPTZ,
                updated_at_src     TIMESTAMPTZ,
                raw_data           JSONB NOT NULL,          -- toutes les infos possibles
                created_at_db      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at_db      TIMESTAMPTZ NOT NULL DEFAULT NOW()
            );
        """)
        conn.commit()

    # Index utiles
    cur.execute(f'CREATE INDEX IF NOT EXISTS idx_{table}_client ON {fq}(client_number);')
    cur.execute(f'CREATE INDEX IF NOT EXISTS idx_{table}_contract ON {fq}(contract_number);')
    cur.execute(f'CREATE INDEX IF NOT EXISTS idx_{table}_status ON {fq}(status);')
    cur.execute(f'CREATE INDEX IF NOT EXISTS idx_{table}_updated_src ON {fq}(updated_at_src);')
    cur.execute(f'CREATE INDEX IF NOT EXISTS idx_{table}_submitted ON {fq}(submitted_on);')
    conn.commit()


def get_watermark(cur, schema, table, default_days_back=365*5):
    """Watermark sur updated_at_src (fallback submitted_on/created_at_src) -> date ISO (YYYY-MM-DD)."""
    fq = qident(schema, table)
    try:
        cur.execute(f"SELECT GREATEST(COALESCE(MAX(updated_at_src), 'epoch'), COALESCE(MAX(submitted_on), 'epoch'), COALESCE(MAX(created_at_src), 'epoch')) FROM {fq};")
        max_dt = cur.fetchone()[0]
        if max_dt:
            return (max_dt - timedelta(days=1)).date().isoformat()
        return (datetime.now(timezone.utc) - timedelta(days=default_days_back)).date().isoformat()
    except Exception as e:
        logger.warning(f"Watermark indisponible, fallback initial: {e}")
        return (datetime.now(timezone.utc) - timedelta(days=default_days_back)).date().isoformat()


def stable_hash(*parts) -> str:
    """Hash de secours quand formId absent."""
    txt = "||".join([str(p or "") for p in parts])
    return hashlib.sha1(txt.encode("utf-8")).hexdigest()


def extract_fields(form: dict) -> tuple:
    """
    Normalise les champs clés + timestamps, et garde le JSON brute.
    Essaie de prendre un identifiant natif (formId | _id), sinon fabrique un hash stable.
    """
    raw = form or {}

    # Identifiants possibles
    form_id = raw.get("formId") or raw.get("_id")
    form_number = raw.get("formNumber") or raw.get("number")

    # Champs fréquents
    name = raw.get("name")
    status = raw.get("status")
    score = raw.get("score")

    client_number = raw.get("clientNumber")
    contract_number = raw.get("contractNumber")

    # agentNumber peut se trouver dans "agent", "assignedTo", etc.
    agent_number = None
    agent = raw.get("agent") or raw.get("assignedTo") or {}
    if isinstance(agent, dict):
        agent_number = agent.get("agentNumber") or agent.get("number") or agent.get("id")
    elif isinstance(agent, str):
        agent_number = agent

    origin = raw.get("origin")

    # Timestamps source
    created_at_src = parse_iso_any(raw.get("createdAt") or raw.get("creationDate"))
    submitted_on = parse_iso_any(raw.get("submittedOn") or raw.get("submittedAt"))
    updated_at_src = parse_iso_any(raw.get("updatedAt") or raw.get("lastUpdated"))

    # Identifiant fallback si nécessaire
    if not form_id:
        form_id = stable_hash(client_number, contract_number, name, submitted_on, updated_at_src)

    return (
        form_id, form_number, name, status, score,
        client_number, contract_number, agent_number, origin,
        created_at_src, submitted_on, updated_at_src,
        json.dumps(raw, ensure_ascii=False)
    )


def main():
    try:
        load_dotenv()
        logger.info("Variables d'environnement chargées")

        # --- API creds ---
        UPYA_USERNAME = os.getenv("UPYA_USERNAME")
        UPYA_PASSWORD = os.getenv("UPYA_PASSWORD")

        # --- DB routing ---
        DB_HOST = os.getenv("DB_HOST")
        DB_PORT = int(os.getenv("DB_PORT") or 5432)
        DB_NAME = os.getenv("DB_NAME")
        DB_USER = os.getenv("DB_USER")
        DB_PASSWORD = os.getenv("DB_PASSWORD")

        DB_SCHEMA = os.getenv("DB_SCHEMA_FORMS") or "public"
        FORMS_TABLE = os.getenv("FORMS_TABLE") or "forms"

        missing = [k for k, v in {
            "UPYA_USERNAME": UPYA_USERNAME, "UPYA_PASSWORD": UPYA_PASSWORD,
            "DB_HOST": DB_HOST, "DB_PORT": DB_PORT, "DB_NAME": DB_NAME,
            "DB_USER": DB_USER, "DB_PASSWORD": DB_PASSWORD
        }.items() if not v]
        if missing:
            raise ValueError(f"Variables d'environnement manquantes: {missing}")

        # --- DB connect ---
        logger.info(f"Connexion PostgreSQL vers {DB_HOST}:{DB_PORT}/{DB_NAME} (schema={DB_SCHEMA}, table={FORMS_TABLE}) ...")
        conn = psycopg2.connect(
            host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
            user=DB_USER, password=DB_PASSWORD,
            sslmode="require", connect_timeout=30
        )
        conn.autocommit = False
        cur = conn.cursor()

        ensure_forms_table(cur, conn, DB_SCHEMA, FORMS_TABLE)
        fq = qident(DB_SCHEMA, FORMS_TABLE)
        logger.info(f"Table prête: {fq}")

        # --- HTTP session ---
        session = build_session(max_retries=3, backoff_factor=1.0)
        auth = HTTPBasicAuth(UPYA_USERNAME, UPYA_PASSWORD)

        # --- Watermark incrémental ---
        watermark = get_watermark(cur, DB_SCHEMA, FORMS_TABLE)
        logger.info(f"Watermark (>=): {watermark}")

        UPSERT_SQL = f"""
        INSERT INTO {fq} (
            form_id, form_number, name, status, score,
            client_number, contract_number, agent_number, origin,
            created_at_src, submitted_on, updated_at_src,
            raw_data
        ) VALUES %s
        ON CONFLICT (form_id) DO UPDATE SET
            form_number     = EXCLUDED.form_number,
            name            = EXCLUDED.name,
            status          = EXCLUDED.status,
            score           = EXCLUDED.score,
            client_number   = EXCLUDED.client_number,
            contract_number = EXCLUDED.contract_number,
            agent_number    = EXCLUDED.agent_number,
            origin          = EXCLUDED.origin,
            created_at_src  = EXCLUDED.created_at_src,
            submitted_on    = EXCLUDED.submitted_on,
            updated_at_src  = EXCLUDED.updated_at_src,
            raw_data        = EXCLUDED.raw_data,
            updated_at_db   = NOW();
        """

        # --- Pagination ---
        page = 1
        per_page = 500
        total_upserts = 0
        error_pages = 0

        # Projection "safe" (si non supportée, on tombera en payload simple)
        used_projection = True

        while True:
            base_query = {
                "$or": [
                    {"updatedAt": {"$gte": watermark}},
                    {"submittedOn": {"$gte": watermark}},
                    {"createdAt": {"$gte": watermark}},
                ]
            }

            payload_projected = {
                "query": base_query,
                "paginate": True,
                "pageNumber": page,
                "nPerPage": per_page,
                "fields": [
                    "formId", "formNumber", "name", "status", "score",
                    "clientNumber", "contractNumber", "agent", "assignedTo", "origin",
                    "createdAt", "submittedOn", "updatedAt"
                ],
                "populate": {
                    "agent": {"select": ["agentNumber", "email", "role"]},
                    "assignedTo": {"select": ["agentNumber"]}
                }
            }
            payload_simple = {
                "query": base_query,
                "paginate": True,
                "pageNumber": page,
                "nPerPage": per_page
            }

            try:
                resp = session.post(
                    API_URL,
                    json=(payload_projected if used_projection else payload_simple),
                    headers=HEADERS,
                    auth=auth,
                    timeout=60
                )
            except requests.RequestException as e:
                error_pages += 1
                logger.error(f"Erreur réseau page {page}: {e}")
                break

            # Fallback si fields/populate ne passent pas
            if resp.status_code in (400, 422) and used_projection:
                logger.warning("Projection/populate non supportés: fallback sur requête simple.")
                used_projection = False
                resp = session.post(API_URL, json=payload_simple, headers=HEADERS, auth=auth, timeout=60)

            if resp.status_code != 200:
                error_pages += 1
                logger.error(f"HTTP {resp.status_code} page {page}: {resp.text[:500]}")
                break

            items = (resp.json() or {}).get("data", [])
            if not items:
                logger.info("Fin de la pagination.")
                break

            rows = []
            for f in items:
                try:
                    rows.append(extract_fields(f))
                except Exception as e:
                    # On ne bloque pas : on trace et on continue
                    logger.warning(f"Form mal formé (page {page}) ignoré: {e}")

            if not rows:
                logger.info(f"Page {page}: 0 formulaire exploitable.")
                page += 1
                continue

            try:
                execute_values(cur, UPSERT_SQL, rows, page_size=200)
                conn.commit()
                total_upserts += len(rows)
                logger.info(f"Page {page}: upsert {len(rows)} (total {total_upserts}).")
            except Exception as e:
                conn.rollback()
                logger.error(f"Erreur DB page {page}, rollback: {e}")

            page += 1
            time.sleep(0.7)

        # --- Résumé ---
        logger.info("=== RÉSULTATS FINAUX ===")
        logger.info(f"Formulaires upsertés: {total_upserts}")
        logger.info(f"Pages en erreur: {error_pages}")

        try:
            cur.execute(f"SELECT COUNT(*) FROM {fq};")
            total = cur.fetchone()[0]
            logger.info(f"Total en base: {total}")
            cur.execute(f"SELECT MIN(submitted_on), MAX(submitted_on) FROM {fq};")
            mind, maxd = cur.fetchone()
            logger.info(f"Période submitted_on: {mind} → {maxd}")
        except Exception as e:
            logger.warning(f"Stats finales indisponibles: {e}")

    except Exception as e:
        logger.error(f"Erreur fatale: {e}", exc_info=True)
        return 1
    finally:
        try:
            if 'cur' in locals(): cur.close()
            if 'conn' in locals(): conn.close()
            logger.info("Connexions fermées")
        except Exception as e:
            logger.error(f"Erreur lors de la fermeture des connexions: {e}")

    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
