# bronze/upya/generic_extractor.py
#
# RÔLE : Extracteur générique pour tous les endpoints UPYA.
# Au lieu de répéter le même code 10 fois, on paramètre
# l'extracteur selon l'endpoint cible.
#
# UTILISATION :
#   python generic_extractor.py contracts
#   python generic_extractor.py assets clients agents
#   python generic_extractor.py   (sans argument = tout)

import os
import sys
import json
import time
import logging
from datetime import datetime, timezone, timedelta

import requests
from requests.auth import HTTPBasicAuth
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from dotenv import load_dotenv

sys.path.append(os.path.join(os.path.dirname(__file__), '..', '..'))
from storage.minio_client import get_minio_client, ensure_bucket_exists, upload_json
from database.db_client import get_db_connection, init_schemas, init_run_log, log_run, get_last_successful_run

logger = logging.getLogger(__name__)

# ============================================================
# Configuration de chaque endpoint UPYA
# ============================================================
ENDPOINTS = {
    "contracts": {
        "url":           "https://data.upya.io/data/search/contracts",
        "per_page":      200,
        "incremental":   False,
        "date_field":    None,
        "default_start": None,
    },
    "assets": {
        "url":           "https://data.upya.io/data/search/assets",
        "per_page":      200,
        "incremental":   False,
        "date_field":    None,
        "default_start": None,
    },
    "clients": {
        "url":           "https://data.upya.io/data/search/clients",
        "per_page":      500,
        "incremental":   False,
        "date_field":    None,
        "default_start": None,
    },
    "agents": {
        "url":           "https://data.upya.io/data/search/agents",
        "per_page":      500,
        "incremental":   True,
        "date_field":    "admin.joinedOn",
        "default_start": "2023-01-01",
    },
    "payments": {
        "url":           "https://data.upya.io/data/search/payments",
        "per_page":      500,
        "incremental":   True,
        "date_field":    "date",
        "default_start": "2023-08-01",
    },
    "tasks": {
        "url":           "https://data.upya.io/data/search/tasks",
        "per_page":      500,
        "incremental":   True,
        "date_field":    "updatedAt",
        "default_start": "2023-01-01",
    },
    "tickets": {
        "url":           "https://data.upya.io/data/search/tickets",
        "per_page":      500,
        "incremental":   False,
        "date_field":    None,
        "default_start": None,
    },
    "forms": {
        "url":           "https://data.upya.io/data/search/forms",
        "per_page":      500,
        "incremental":   True,
        "date_field":    "updatedAt",
        "default_start": "2023-01-01",
    },
    "deals": {
        "url":           "https://data.upya.io/data/deals/search",
        "per_page":      200,
        "incremental":   False,
        "date_field":    None,
        "default_start": None,
    },
    "asset_events": {
        "url":           "https://data.upya.io/data/search/asset-events",
        "per_page":      500,
        "incremental":   True,
        "date_field":    "updatedAt",
        "default_start": "2023-01-01",
    },
}

HEADERS = {"Content-Type": "application/json", "Accept": "application/json"}


def build_session():
    """Session HTTP avec retry automatique."""
    session = requests.Session()
    retry = Retry(
        total=3,
        backoff_factor=1.0,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=("POST",),
    )
    session.mount("https://", HTTPAdapter(max_retries=retry))
    return session


def get_watermark(conn, entity, default_start):
    """
    Retourne la date de départ pour l'extraction.
    Si aucun run précédent → retourne default_start.
    """
    last_run = get_last_successful_run(conn, "upya", entity)
    if last_run:
        watermark = last_run["run_date"] - timedelta(days=1)
        logger.info(f"[{entity}] Watermark → {watermark}")
        return watermark.isoformat()
    logger.info(f"[{entity}] Premier run → {default_start}")
    return default_start


def get_item_id(item, entity_name):
    """
    Extrait l'identifiant unique d'un item selon l'entité.

    Utilisé pour la détection de boucle infinie :
    si on voit les mêmes IDs deux fois, on s'arrête.

    Chaque endpoint a son propre champ d'identifiant :
    - contracts   → contractNumber
    - assets      → paygNumber
    - clients     → clientNumber
    - payments    → transactionId
    - deals       → dealNumber
    - etc.
    """
    id_fields = {
        "contracts":    ["contractNumber", "_id"],
        "assets":       ["paygNumber", "_id"],
        "clients":      ["clientNumber", "_id"],
        "agents":       ["agentNumber", "_id"],
        "payments":     ["transactionId", "_id"],
        "tasks":        ["taskId", "_id"],
        "tickets":      ["ticketId", "_id"],
        "forms":        ["formId", "_id"],
        "deals":        ["dealNumber", "_id"],
        "asset_events": ["_id"],
    }

    fields = id_fields.get(entity_name, ["_id"])
    for field in fields:
        val = item.get(field)
        if val:
            return str(val)

    # Fallback : hash du contenu si aucun ID trouvé
    return str(hash(json.dumps(item, sort_keys=True, default=str)))


def extract_entity(entity_name, conn, minio_client, bucket, auth, session):
    """
    Extrait une entité UPYA et la sauvegarde dans MinIO Bronze.

    Inclut une détection de boucle infinie : si l'API retourne
    les mêmes données indéfiniment (comportement de certains
    endpoints comme 'deals'), on s'arrête proprement.

    Args:
        entity_name : "payments", "contracts", "deals"...
        conn        : connexion PostgreSQL
        minio_client: client MinIO
        bucket      : nom du bucket
        auth        : credentials UPYA
        session     : session HTTP

    Returns:
        dict avec pages_fetched, rows_count, minio_prefix
    """
    config = ENDPOINTS.get(entity_name)
    if not config:
        raise ValueError(f"Entité inconnue : {entity_name}")

    url      = config["url"]
    per_page = config["per_page"]
    now      = datetime.now(timezone.utc)
    date_path = now.strftime("%Y/%m/%d")
    minio_prefix = f"bronze/upya/{entity_name}/{date_path}/"

    # Construction du filtre de date si incremental
    if config["incremental"] and config["date_field"]:
        start_date = get_watermark(conn, entity_name, config["default_start"])
        query = {config["date_field"]: {"$gte": start_date}}
        logger.info(f"[{entity_name}] Mode incrémental depuis {start_date}")
    else:
        query = {}
        logger.info(f"[{entity_name}] Mode full reload")

    page       = 1
    total_rows = 0

    # seen_ids : ensemble de tous les IDs déjà vus
    # Si une page entière contient des IDs déjà vus →
    # l'API boucle → on arrête
    seen_ids = set()

    while True:
        payload = {
            "query":      query,
            "paginate":   True,
            "pageNumber": page,
            "nPerPage":   per_page,
        }

        # deals nécessite ce paramètre supplémentaire
        if entity_name == "deals":
            payload["includeOldVersions"] = True

        try:
            resp = session.post(
                url, json=payload,
                headers=HEADERS, auth=auth,
                timeout=60
            )
        except requests.RequestException as e:
            logger.error(f"[{entity_name}] Erreur réseau p.{page}: {e}")
            break

        if resp.status_code != 200:
            logger.error(f"[{entity_name}] HTTP {resp.status_code} p.{page}")
            break

        raw   = resp.json()
        items = raw.get("data", raw) if isinstance(raw, dict) else raw

        # Condition 1 : page vide → fin normale
        if not items:
            logger.info(f"[{entity_name}] Fin pagination p.{page - 1}")
            break

        # Condition 2 : détection de boucle infinie
        # On extrait les IDs de cette page
        page_ids = {get_item_id(item, entity_name) for item in items}

        # Si TOUS les IDs de cette page ont déjà été vus → boucle !
        new_ids = page_ids - seen_ids
        if not new_ids:
            logger.info(
                f"[{entity_name}] Boucle infinie détectée "
                f"à la page {page} — arrêt propre"
            )
            break

        # On mémorise les nouveaux IDs
        seen_ids.update(page_ids)

        logger.info(f"[{entity_name}] Page {page}: {len(items)} items")

        # Sauvegarde Bronze — données brutes, aucune modification
        page_json = json.dumps(items, ensure_ascii=False, default=str)
        upload_json(
            client=minio_client,
            bucket_name=bucket,
            data=page_json,
            source="upya",
            entity=entity_name,
            page=page,
        )

        total_rows += len(items)
        page += 1
        time.sleep(0.5)

    return {
        "pages_fetched": page - 1,
        "rows_count":    total_rows,
        "minio_prefix":  minio_prefix,
    }


def run_extraction(entity_names=None):
    """
    Lance l'extraction pour une liste d'entités.

    Args:
        entity_names: liste d'entités à extraire
                      None = toutes les entités
    """
    load_dotenv()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s"
    )

    if entity_names is None:
        entity_names = list(ENDPOINTS.keys())

    upya_user = os.getenv("UPYA_USERNAME")
    upya_pass = os.getenv("UPYA_PASSWORD")
    if not upya_user or not upya_pass:
        raise ValueError("UPYA_USERNAME et UPYA_PASSWORD requis dans .env")

    auth    = HTTPBasicAuth(upya_user, upya_pass)
    session = build_session()

    minio_client = get_minio_client()
    bucket       = os.getenv("MINIO_BUCKET", "paygo-lakehouse")
    ensure_bucket_exists(minio_client, bucket)

    conn = get_db_connection()
    init_schemas(conn)
    init_run_log(conn)

    results = {}

    for entity in entity_names:
        logger.info("=" * 50)
        logger.info(f"EXTRACTION : {entity.upper()}")
        logger.info("=" * 50)
        start_time = time.time()

        try:
            result = extract_entity(
                entity_name  = entity,
                conn         = conn,
                minio_client = minio_client,
                bucket       = bucket,
                auth         = auth,
                session      = session,
            )
            duration = time.time() - start_time

            log_run(
                conn          = conn,
                source        = "upya",
                entity        = entity,
                status        = "success",
                pages_fetched = result["pages_fetched"],
                rows_count    = result["rows_count"],
                minio_prefix  = result["minio_prefix"],
                duration_sec  = duration,
            )

            results[entity] = {
                "status":   "✅ success",
                "rows":     result["rows_count"],
                "pages":    result["pages_fetched"],
                "duration": f"{duration:.1f}s",
            }

        except Exception as e:
            duration = time.time() - start_time
            log_run(
                conn          = conn,
                source        = "upya",
                entity        = entity,
                status        = "error",
                error_message = str(e),
                duration_sec  = duration,
            )
            logger.error(f"[{entity}] Erreur : {e}", exc_info=True)
            results[entity] = {
                "status": "❌ error",
                "error":  str(e)
            }

    conn.close()

    # Résumé final
    logger.info("\n" + "=" * 50)
    logger.info("RÉSUMÉ EXTRACTION UPYA")
    logger.info("=" * 50)
    for entity, res in results.items():
        if res["status"].startswith("✅"):
            logger.info(
                f"{res['status']} {entity:15} "
                f"rows={res['rows']:>6} "
                f"pages={res['pages']:>4} "
                f"({res['duration']})"
            )
        else:
            logger.info(
                f"{res['status']} {entity:15} "
                f"→ {res.get('error','')[:50]}"
            )

    return results


# POINT D'ENTRÉE
# python bronze/upya/generic_extractor.py deals
# python bronze/upya/generic_extractor.py assets clients
# python bronze/upya/generic_extractor.py   (= tout)

if __name__ == "__main__":
    entities = sys.argv[1:] if len(sys.argv) > 1 else None
    run_extraction(entities)