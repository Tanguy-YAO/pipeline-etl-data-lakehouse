# silver/upya/generic_loader.py
#
# RÔLE : Loader générique pour les entités UPYA simples.
# Lit les JSON Bronze MinIO et charge dans PostgreSQL Silver.
#
# CORRECTIF (21/08/2026) : watermark Silver ajouté -- ne relit plus
# TOUT l'historique Bronze à chaque run (cause du timeout de 90min
# sur assets le 21/08/2026), seulement les fichiers non encore
# traités avec succès. Voir silver_meta.load_watermark.
#
# CORRECTIF (28/08/2026) : deploy_date et date_added manquaient dans
# le ON CONFLICT DO UPDATE de assets -- un asset extrait AVANT son
# déploiement physique (deploy_date=NULL à ce moment) restait bloqué
# à NULL pour toujours, même une fois réellement déployé et remonté
# avec la vraie date lors d'une extraction ultérieure. Cause directe
# du faible taux de remplissage de deploy_date (37,9% observé) et de
# la sous-estimation des activations récentes dans les dashboards.
# Nécessite un rechargement complet après déploiement (watermark reset)
# pour réparer l'historique déjà figé en base par ce bug.
#
# CORRECTIF (05/09/2026) : ajout entité agents
# CORRECTIF (27/09/2026) : ajout entités tasks et forms

import os
import sys
import json
import logging
import time
from psycopg2.extras import execute_values
from dotenv import load_dotenv

sys.path.append(os.path.join(os.path.dirname(__file__), '..', '..'))
from storage.minio_client import get_minio_client, list_bronze_files, download_json
from database.db_client import (
    get_db_connection, init_schemas,
    get_load_watermark, set_load_watermark
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Configuration des entités
ENTITIES = {
    "assets": {
        "create_sql": """
            CREATE TABLE IF NOT EXISTS silver.upya_assets (
                payg_number        TEXT PRIMARY KEY,
                asset_id           TEXT,
                serial_number      TEXT,
                status             TEXT,
                product_reference  TEXT,
                contract_number    TEXT,
                client_number      TEXT,
                held_by            TEXT,
                batch_number       TEXT,
                deploy_date        TIMESTAMPTZ,
                date_added         TIMESTAMPTZ,
                distributed_status TEXT,
                loaded_at          TIMESTAMPTZ DEFAULT NOW(),
                updated_at         TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE INDEX IF NOT EXISTS idx_upya_assets_contract
                ON silver.upya_assets(contract_number);
            CREATE INDEX IF NOT EXISTS idx_upya_assets_status
                ON silver.upya_assets(status);
        """,
        "upsert_sql": """
            INSERT INTO silver.upya_assets (
                payg_number, asset_id, serial_number, status,
                product_reference, contract_number, client_number,
                held_by, batch_number, deploy_date, date_added,
                distributed_status
            ) VALUES %s
            ON CONFLICT (payg_number) DO UPDATE SET
                status             = EXCLUDED.status,
                contract_number    = EXCLUDED.contract_number,
                client_number      = EXCLUDED.client_number,
                held_by            = EXCLUDED.held_by,
                distributed_status = EXCLUDED.distributed_status,
                deploy_date        = EXCLUDED.deploy_date,
                date_added         = EXCLUDED.date_added,
                updated_at         = NOW();
        """,
        "transform": lambda item: _transform_asset(item),
    },
    "clients": {
        "create_sql": """
            CREATE TABLE IF NOT EXISTS silver.upya_clients (
                client_number    TEXT PRIMARY KEY,
                status           TEXT,
                first_name       TEXT,
                last_name        TEXT,
                gender           TEXT,
                mobile           TEXT,
                village          TEXT,
                district         TEXT,
                region           TEXT,
                country          TEXT,
                entry_date       TIMESTAMPTZ,
                loaded_at        TIMESTAMPTZ DEFAULT NOW(),
                updated_at       TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE INDEX IF NOT EXISTS idx_upya_clients_status
                ON silver.upya_clients(status);
        """,
        "upsert_sql": """
            INSERT INTO silver.upya_clients (
                client_number, status, first_name, last_name,
                gender, mobile, village, district, region,
                country, entry_date
            ) VALUES %s
            ON CONFLICT (client_number) DO UPDATE SET
                status     = EXCLUDED.status,
                mobile     = EXCLUDED.mobile,
                updated_at = NOW();
        """,
        "transform": lambda item: _transform_client(item),
    },
    "deals": {
        "create_sql": """
            CREATE TABLE IF NOT EXISTS silver.upya_deals (
                deal_number          TEXT PRIMARY KEY,
                deal_name            TEXT,
                type                 TEXT,
                status               TEXT,
                total_cost           NUMERIC(18,2),
                pricing_recurring    NUMERIC(18,2),
                pricing_days         INTEGER,
                pricing_upfront      NUMERIC(18,2),
                set_up_on            TIMESTAMPTZ,
                loaded_at            TIMESTAMPTZ DEFAULT NOW(),
                updated_at           TIMESTAMPTZ DEFAULT NOW()
            );
        """,
        "upsert_sql": """
            INSERT INTO silver.upya_deals (
                deal_number, deal_name, type, status,
                total_cost, pricing_recurring, pricing_days,
                pricing_upfront, set_up_on
            ) VALUES %s
            ON CONFLICT (deal_number) DO UPDATE SET
                status            = EXCLUDED.status,
                total_cost        = EXCLUDED.total_cost,
                pricing_recurring = EXCLUDED.pricing_recurring,
                updated_at        = NOW();
        """,
        "transform": lambda item: _transform_deal(item),
    },
    "agents": {
        "create_sql": """
            CREATE TABLE IF NOT EXISTS silver.upya_agents (
                agent_number     TEXT PRIMARY KEY,
                internal_number  TEXT,
                first_name       TEXT,
                last_name        TEXT,
                gender           TEXT,
                mobile           TEXT,
                email            TEXT,
                role             TEXT,
                entity_name      TEXT,
                country          TEXT,
                country_code     TEXT,
                updated_at_src   TIMESTAMPTZ,
                loaded_at        TIMESTAMPTZ DEFAULT NOW(),
                updated_at       TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE INDEX IF NOT EXISTS idx_upya_agents_entity
                ON silver.upya_agents(entity_name);
        """,
        "upsert_sql": """
            INSERT INTO silver.upya_agents (
                agent_number, internal_number, first_name, last_name,
                gender, mobile, email, role, entity_name,
                country, country_code, updated_at_src
            ) VALUES %s
            ON CONFLICT (agent_number) DO UPDATE SET
                first_name     = EXCLUDED.first_name,
                last_name      = EXCLUDED.last_name,
                gender         = EXCLUDED.gender,
                mobile         = EXCLUDED.mobile,
                email          = EXCLUDED.email,
                role           = EXCLUDED.role,
                entity_name    = EXCLUDED.entity_name,
                updated_at_src = EXCLUDED.updated_at_src,
                updated_at     = NOW();
        """,
        "transform": lambda item: _transform_agent(item),
    },
    "tasks": {
        "create_sql": """
            CREATE TABLE IF NOT EXISTS silver.upya_tasks (
                task_id               TEXT PRIMARY KEY,
                task_number           TEXT,
                title                 TEXT,
                instructions          TEXT,
                assigned_on           TIMESTAMPTZ,
                due_on                TIMESTAMPTZ,
                completed_on          TIMESTAMPTZ,
                closed_on             TIMESTAMPTZ,
                assigned_to           TEXT,
                assigned_to_last_name TEXT,
                contract_number       TEXT,
                client_number         TEXT,
                parent_ticket         TEXT,
                updated_at_src        TIMESTAMPTZ,
                loaded_at             TIMESTAMPTZ DEFAULT NOW(),
                updated_at            TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE INDEX IF NOT EXISTS idx_upya_tasks_contract
                ON silver.upya_tasks(contract_number);
            CREATE INDEX IF NOT EXISTS idx_upya_tasks_client
                ON silver.upya_tasks(client_number);
        """,
        "upsert_sql": """
            INSERT INTO silver.upya_tasks (
                task_id, task_number, title, instructions,
                assigned_on, due_on, completed_on, closed_on,
                assigned_to, assigned_to_last_name,
                contract_number, client_number,
                parent_ticket, updated_at_src
            ) VALUES %s
            ON CONFLICT (task_id) DO UPDATE SET
                title                 = EXCLUDED.title,
                completed_on          = EXCLUDED.completed_on,
                closed_on             = EXCLUDED.closed_on,
                assigned_to           = EXCLUDED.assigned_to,
                updated_at_src        = EXCLUDED.updated_at_src,
                updated_at            = NOW();
        """,
        "transform": lambda item: _transform_task(item),
    },
    "forms": {
        "create_sql": """
            CREATE TABLE IF NOT EXISTS silver.upya_forms (
                form_id            TEXT PRIMARY KEY,
                questionnaire_name TEXT,
                contract_number    TEXT,
                client_number      TEXT,
                collector_number   TEXT,
                collector_name     TEXT,
                credit_agent_ref   TEXT,
                survey             BOOLEAN,
                paid               BOOLEAN,
                form_date          TIMESTAMPTZ,
                created_at_src     TIMESTAMPTZ,
                updated_at_src     TIMESTAMPTZ,
                raw_data           JSONB,
                loaded_at          TIMESTAMPTZ DEFAULT NOW(),
                updated_at         TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE INDEX IF NOT EXISTS idx_upya_forms_contract
                ON silver.upya_forms(contract_number);
            CREATE INDEX IF NOT EXISTS idx_upya_forms_client
                ON silver.upya_forms(client_number);
            CREATE INDEX IF NOT EXISTS idx_upya_forms_date
                ON silver.upya_forms(form_date);
        """,
        "upsert_sql": """
            INSERT INTO silver.upya_forms (
                form_id, questionnaire_name, contract_number,
                client_number, collector_number, collector_name,
                credit_agent_ref, survey, paid, form_date,
                created_at_src, updated_at_src, raw_data
            ) VALUES %s
            ON CONFLICT (form_id) DO UPDATE SET
                questionnaire_name = EXCLUDED.questionnaire_name,
                updated_at_src     = EXCLUDED.updated_at_src,
                raw_data           = EXCLUDED.raw_data,
                updated_at         = NOW();
        """,
        "transform": lambda item: _transform_form(item),
    },
    "tickets": {
        "create_sql": """
            CREATE TABLE IF NOT EXISTS silver.upya_tickets (
                ticket_id         TEXT PRIMARY KEY,
                ticket_number     TEXT,
                status            TEXT,
                progress          TEXT,
                title             TEXT,
                contract_number   TEXT,
                client_number     TEXT,
                origin            TEXT,
                created_at_src    TIMESTAMPTZ,
                updated_at_src    TIMESTAMPTZ,
                loaded_at         TIMESTAMPTZ DEFAULT NOW(),
                updated_at        TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE INDEX IF NOT EXISTS idx_upya_tickets_contract
                ON silver.upya_tickets(contract_number);
            CREATE INDEX IF NOT EXISTS idx_upya_tickets_client
                ON silver.upya_tickets(client_number);
        """,
        "upsert_sql": """
            INSERT INTO silver.upya_tickets (
                ticket_id, ticket_number, status, progress, title,
                contract_number, client_number, origin,
                created_at_src, updated_at_src
            ) VALUES %s
            ON CONFLICT (ticket_id) DO UPDATE SET
                status         = EXCLUDED.status,
                progress       = EXCLUDED.progress,
                updated_at_src = EXCLUDED.updated_at_src,
                updated_at     = NOW();
        """,
        "transform": lambda item: _transform_ticket(item),
    },
}

def _parse_date(v):
    if not v:
        return None
    from datetime import datetime, timezone
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            return datetime.strptime(v, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def _parse_date_task(v):
    """Parse le format spécifique des dates dans upya_tasks : '12-Jun-2025 02:39:42'"""
    if not v:
        return None
    from datetime import datetime, timezone
    try:
        return datetime.strptime(v, "%d-%b-%Y %H:%M:%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _parse_amount(v):
    if v is None:
        return None
    try:
        return float(str(v).replace(",", ""))
    except Exception:
        return None


def _transform_asset(item):
    payg_number = item.get("paygNumber")
    if not payg_number:
        return None
    product     = item.get("product")     or {}
    contract    = item.get("contract")    or {}
    owned_by    = item.get("ownedBy")     or {}
    held_by     = item.get("heldBy")      or {}
    distributed = item.get("distributed") or {}
    return (
        str(payg_number),
        item.get("_id"),
        item.get("serialNumber"),
        item.get("status"),
        product.get("reference"),
        contract.get("contractNumber"),
        owned_by.get("clientNumber"),
        held_by.get("agentNumber"),
        item.get("batchNumber"),
        _parse_date(item.get("deployDate")),
        _parse_date(item.get("dateAdded")),
        distributed.get("status") if isinstance(distributed, dict) else None,
    )


def _transform_client(item):
    client_number = item.get("clientNumber")
    if not client_number:
        return None
    profile = item.get("profile") or {}
    contact = item.get("contact") or {}
    return (
        str(client_number),
        item.get("status"),
        profile.get("firstName"),
        profile.get("lastName"),
        profile.get("gender"),
        contact.get("mobile"),
        profile.get("village"),
        profile.get("district"),
        profile.get("region"),
        profile.get("country"),
        _parse_date(item.get("entryDate")),
    )


def _transform_deal(item):
    deal_number = item.get("dealNumber")
    if not deal_number:
        return None
    pricing = item.get("pricingSchedule") or {}
    return (
        str(deal_number),
        item.get("dealName"),
        item.get("type"),
        item.get("status"),
        _parse_amount(item.get("totalCost")),
        _parse_amount(pricing.get("recurring")),
        pricing.get("days"),
        _parse_amount(pricing.get("upfront")),
        _parse_date(item.get("setUpOn")),
    )


def _transform_agent(item):
    agent_number = item.get("agentNumber")
    if not agent_number:
        return None
    profile = item.get("profile") or {}
    contact = item.get("contact") or {}
    entity  = item.get("entity")  or {}
    return (
        str(agent_number),
        item.get("internalNumber"),
        profile.get("firstName"),
        profile.get("lastName"),
        profile.get("gender"),
        str(contact.get("mobile")) if contact.get("mobile") else None,
        contact.get("email") or item.get("email"),
        item.get("role"),
        entity.get("name"),
        item.get("country"),
        item.get("countryCode"),
        _parse_date(item.get("updatedAt")),
    )


def _transform_task(item):
    task_id = item.get("taskId")
    if not task_id:
        return None
    return (
        str(task_id),
        item.get("taskNumber"),
        item.get("title"),
        item.get("instructions"),
        _parse_date_task(item.get("assignedOn")),
        _parse_date_task(item.get("dueOn")),
        _parse_date_task(item.get("completedOn")),
        _parse_date_task(item.get("closedOn")),
        item.get("assignedTo"),
        item.get("assignedToLastName"),
        item.get("contractNumber"),
        item.get("clientNumber"),
        item.get("parentTicket"),
        _parse_date(item.get("updatedAt")),
    )


def _transform_form(item):
    form_id = item.get("_id")
    if not form_id:
        return None
    questionnaire     = item.get("questionnaire") or {}
    collector         = item.get("collector")     or {}
    collector_profile = collector.get("profile")  or {}
    contract          = item.get("contract")      or {}
    client            = item.get("client")        or {}
    collector_name    = f"{collector_profile.get('firstName', '')} {collector_profile.get('lastName', '')}".strip() or None
    return (
        str(form_id),
        questionnaire.get("name"),
        contract.get("contractNumber"),
        client.get("clientNumber"),
        collector.get("userNumber"),
        collector_name,
        item.get("creditAgentReference"),
        bool(item.get("survey", False)),
        bool(item.get("paid", False)),
        _parse_date(item.get("date")),
        _parse_date(item.get("createdAt")),
        _parse_date(item.get("updatedAt")),
        json.dumps(item.get("creditItems", []), ensure_ascii=False),
    )

def _transform_ticket(item):
    ticket_id = item.get("ticketId")
    if not ticket_id:
        return None
    return (
        str(ticket_id),
        item.get("ticketNumber"),
        item.get("status"),
        item.get("progress"),
        item.get("title"),
        item.get("contractNumber"),
        item.get("clientNumber"),
        item.get("origin"),
        _parse_date(item.get("createdAt")),
        _parse_date(item.get("updatedAt")),
    )

def load_entity(entity_name, date=None):
    load_dotenv()
    start_time = time.time()

    config = ENTITIES.get(entity_name)
    if not config:
        raise ValueError(f"Entité inconnue : {entity_name}")

    logger.info(f"SILVER LOADER — UPYA {entity_name.upper()}")

    minio_client = get_minio_client()
    bucket       = os.getenv("MINIO_BUCKET", "paygo-lakehouse")
    conn         = get_db_connection()

    init_schemas(conn)
    cur = conn.cursor()
    cur.execute(config["create_sql"])
    conn.commit()
    cur.close()
    logger.info(f"Table silver.upya_{entity_name} prête")

    since = date if date else get_load_watermark(conn, "upya", entity_name)
    files = list_bronze_files(minio_client, bucket, "upya", entity_name, since_date=since)

    if not files:
        logger.warning(f"Aucun nouveau fichier Bronze pour {entity_name} depuis le dernier chargement")
        conn.close()
        return 0

    logger.info(f"Fichiers à traiter : {len(files)} (depuis {since or 'le début'})")

    total_rows    = 0
    total_errors  = 0
    max_date_seen = since

    for file_key in files:
        try:
            content = download_json(minio_client, bucket, file_key)
            items   = json.loads(content)

            rows = []
            for item in items:
                row = config["transform"](item)
                if row:
                    rows.append(row)
                else:
                    total_errors += 1

            if rows:
                cur = conn.cursor()
                page_size = 100 if entity_name == "forms" else 500
                execute_values(cur, config["upsert_sql"], rows, page_size=page_size)
                conn.commit()
                cur.close()
                total_rows += len(rows)
                logger.info(f"  {file_key.split('/')[-1]} → {len(rows)} lignes")

            path_parts = file_key.split("/")
            file_date = "/".join(path_parts[3:6])
            if max_date_seen is None or file_date > max_date_seen:
                max_date_seen = file_date

        except Exception as e:
            conn.rollback()
            logger.error(f"Erreur {file_key} : {e}")
            total_errors += 1

    if total_errors == 0 and max_date_seen and not date:
        set_load_watermark(conn, "upya", entity_name, max_date_seen)
        logger.info(f"Watermark Silver mis à jour ({entity_name}) : {max_date_seen}")
    elif total_errors > 0:
        logger.warning(f"{total_errors} erreur(s) — watermark {entity_name} non avancé, retraité au prochain run")

    duration = time.time() - start_time
    logger.info(f"TERMINE — {entity_name.upper()} : {total_rows:,} lignes / {total_errors} erreurs / {duration:.1f}s")

    conn.close()
    return total_rows


if __name__ == "__main__":
    entities = sys.argv[1:] if len(sys.argv) > 1 else list(ENTITIES.keys())
    for entity in entities:
        load_entity(entity)