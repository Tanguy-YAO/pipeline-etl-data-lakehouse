# asset_events_extractor.py
# Extrait les événements assets depuis l'API UPYA
# et les charge dans silver.upya_asset_events (Railway)
import os
import json
import time
import logging
from datetime import datetime, timedelta, timezone
import requests
from requests.auth import HTTPBasicAuth
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
import psycopg2
from psycopg2.extras import execute_values, Json
from dotenv import load_dotenv
import sys
sys.path.append('.')
from database.db_client import get_db_connection

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)

API_URL   = "https://data.upya.io/data/search/asset-events"
HEADERS   = {"Content-Type": "application/json", "Accept": "application/json"}
TABLE     = "silver.upya_asset_events"

def parse_iso_utc(s):
    if not s:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d %H:%M:%S%z", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d"):
        try:
            dt = datetime.strptime(s, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc)
        except ValueError:
            continue
    return None

def safe_get(obj, *keys, default=None):
    try:
        cur = obj
        for key in keys:
            if cur is None:
                return default
            if isinstance(key, str) and "." in key:
                for p in key.split("."):
                    cur = cur.get(p) if isinstance(cur, dict) else (cur[int(p)] if isinstance(cur, list) and p.isdigit() else None)
            else:
                cur = cur.get(key) if isinstance(cur, dict) else (cur[key] if isinstance(cur, list) and isinstance(key, int) else None)
        return cur if cur is not None else default
    except Exception:
        return default

def pick(obj, *paths):
    for p in paths:
        v = safe_get(obj, p)
        if v not in (None, "", []):
            return v
    return None

def build_session():
    s = requests.Session()
    retry = Retry(total=3, backoff_factor=1.0, status_forcelist=(429,500,502,503,504), allowed_methods=("GET","POST"))
    s.mount("https://", HTTPAdapter(max_retries=retry))
    return s

def ensure_schema(cur, conn):
    cur.execute(f"""
        CREATE TABLE IF NOT EXISTS {TABLE} (
            event_id                TEXT PRIMARY KEY,
            asset_id                TEXT,
            payg_number             TEXT,
            event_type              TEXT,
            event_status            TEXT,
            event_date              TIMESTAMPTZ,
            event_note              TEXT,
            created_at_src          TIMESTAMPTZ,
            updated_at_src          TIMESTAMPTZ,
            asset_number            TEXT,
            serial_number           TEXT,
            batch_number            TEXT,
            product_reference       TEXT,
            asset_date_added        TIMESTAMPTZ,
            asset_last_update       TIMESTAMPTZ,
            product_name            TEXT,
            product_category        TEXT,
            product_manufacturer    TEXT,
            actor                   TEXT,
            agent_number            TEXT,
            agent_first_name        TEXT,
            agent_last_name         TEXT,
            old_holder_agent_number TEXT,
            old_holder_first_name   TEXT,
            old_holder_last_name    TEXT,
            new_holder_agent_number TEXT,
            new_holder_first_name   TEXT,
            new_holder_last_name    TEXT,
            location                TEXT,
            coordinates             JSONB,
            source                  TEXT,
            raw_data                JSONB,
            created_at              TIMESTAMPTZ DEFAULT NOW(),
            updated_at_db           TIMESTAMPTZ DEFAULT NOW()
        )
    """)
    for idx in [
        f"CREATE INDEX IF NOT EXISTS idx_asset_events_date   ON {TABLE}(event_date)",
        f"CREATE INDEX IF NOT EXISTS idx_asset_events_payg   ON {TABLE}(payg_number)",
        f"CREATE INDEX IF NOT EXISTS idx_asset_events_type   ON {TABLE}(event_type)",
        f"CREATE INDEX IF NOT EXISTS idx_asset_events_upd    ON {TABLE}(updated_at_src)",
    ]:
        cur.execute(idx)
    conn.commit()
    logger.info(f"Table {TABLE} prête")

UPSERT_SQL = f"""
INSERT INTO {TABLE} (
    event_id, asset_id, payg_number, event_type, event_status,
    event_date, event_note, created_at_src, updated_at_src,
    asset_number, serial_number, batch_number, product_reference,
    asset_date_added, asset_last_update, product_name, product_category,
    product_manufacturer, actor, agent_number, agent_first_name,
    agent_last_name, old_holder_agent_number, old_holder_first_name,
    old_holder_last_name, new_holder_agent_number, new_holder_first_name,
    new_holder_last_name, location, coordinates, source, raw_data
) VALUES %s
ON CONFLICT (event_id) DO UPDATE SET
    event_type              = EXCLUDED.event_type,
    event_status            = EXCLUDED.event_status,
    event_date              = EXCLUDED.event_date,
    event_note              = EXCLUDED.event_note,
    updated_at_src          = EXCLUDED.updated_at_src,
    asset_last_update       = EXCLUDED.asset_last_update,
    location                = EXCLUDED.location,
    raw_data                = EXCLUDED.raw_data,
    updated_at_db           = NOW()
"""

def get_watermark(cur):
    try:
        cur.execute(f"SELECT MAX(updated_at_src) FROM {TABLE}")
        max_dt = cur.fetchone()[0]
        if max_dt:
            wm = (max_dt - timedelta(days=1)).date().isoformat()
            logger.info(f"Watermark depuis DB : {wm}")
            return wm
    except Exception:
        pass
    wm = (datetime.now(timezone.utc) - timedelta(days=365*3)).date().isoformat()
    logger.info(f"Watermark par défaut : {wm}")
    return wm

def extract_fields(ev):
    return (
        pick(ev, "_id", "id"),
        pick(ev, "asset._id", "assetId"),
        pick(ev, "asset.paygNumber", "paygNumber"),
        pick(ev, "type", "eventType"),
        pick(ev, "status", "eventStatus"),
        parse_iso_utc(pick(ev, "date", "eventDate")),
        pick(ev, "note", "description"),
        parse_iso_utc(pick(ev, "createdAt")),
        parse_iso_utc(pick(ev, "updatedAt", "date")),
        pick(ev, "asset.assetNumber", "assetNumber"),
        pick(ev, "asset.serialNumber", "serialNumber"),
        pick(ev, "asset.batchNumber", "batchNumber"),
        pick(ev, "asset.productReference", "product.productReference"),
        parse_iso_utc(pick(ev, "asset.dateAdded")),
        parse_iso_utc(pick(ev, "asset.lastUpdate")),
        pick(ev, "asset.productDetails.name", "product.name"),
        pick(ev, "asset.productDetails.category", "product.category"),
        pick(ev, "asset.productDetails.manufacturer", "product.manufacturer"),
        pick(ev, "actor.agentNumber", "actor.name"),
        pick(ev, "newHolder.agentNumber", "agent.agentNumber"),
        pick(ev, "newHolder.profile.firstName"),
        pick(ev, "newHolder.profile.lastName"),
        pick(ev, "oldHolder.agentNumber"),
        pick(ev, "oldHolder.profile.firstName"),
        pick(ev, "oldHolder.profile.lastName"),
        pick(ev, "newHolder.agentNumber"),
        pick(ev, "newHolder.profile.firstName"),
        pick(ev, "newHolder.profile.lastName"),
        pick(ev, "location"),
        pick(ev, "coordinates", "gps"),
        pick(ev, "source"),
        ev
    )

def main():
    load_dotenv()
    UPYA_USERNAME = os.getenv("UPYA_USERNAME")
    UPYA_PASSWORD = os.getenv("UPYA_PASSWORD")

    conn = get_db_connection()
    conn.autocommit = False
    cur  = conn.cursor()

    ensure_schema(cur, conn)

    watermark = get_watermark(cur)
    session   = build_session()
    auth      = HTTPBasicAuth(UPYA_USERNAME, UPYA_PASSWORD)

    page, total = 1, 0
    seen_ids = set()

    while True:
        payload = {
            "query": {"updatedAt": {"$gte": watermark}},
            "paginate": True, "pageNumber": page, "nPerPage": 500
        }
        try:
            resp = session.post(API_URL, json=payload, headers=HEADERS, auth=auth, timeout=90)
        except Exception as e:
            logger.error(f"Erreur réseau page {page}: {e}")
            break

        if resp.status_code != 200:
            logger.error(f"HTTP {resp.status_code} page {page}")
            break

        events = (resp.json() or {}).get("data", [])
        if not events:
            logger.info("Fin de pagination")
            break

        rows = []
        for ev in events:
            fields = extract_fields(ev)
            event_id = fields[0]
            if not event_id or event_id in seen_ids:
                continue
            seen_ids.add(event_id)
            row = list(fields)
            if isinstance(row[-2], (dict, list)):
                row[-2] = Json(row[-2])
            row[-1] = Json(row[-1])
            rows.append(tuple(row))

        if rows:
            try:
                execute_values(cur, UPSERT_SQL, rows, page_size=200)
                conn.commit()
                total += len(rows)
                logger.info(f"Page {page} : {len(rows)} events | total : {total:,}")
            except Exception as e:
                conn.rollback()
                logger.error(f"Erreur DB page {page}: {e}")

        page += 1
        time.sleep(0.5)

    cur.execute(f"SELECT COUNT(*), COUNT(CASE WHEN event_type='DEPLOYED' THEN 1 END) FROM {TABLE}")
    row = cur.fetchone()
    logger.info(f"Total events : {row[0]:,} | DEPLOYED : {row[1]:,}")
    cur.close()
    conn.close()

if __name__ == "__main__":
    main()