# silver/upya/generic_loader.py  (v2, 11/11/2026)
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
#
# CORRECTIF v2 (11/11/2026, audit DELTA) :
# - Le ON CONFLICT DO UPDATE ne mettait à jour qu'une partie des colonnes.
#   clients : seuls status et mobile suivaient ; prénom, nom, genre,
#   village, district, région restaient figés à la première insertion
#   (cas C903641332 : fiche renommée Youssouf Kone dans UPYA, DELTA gardait
#   Pierrot Ouloubonmou ; 181 contrats au contrôle G). Même défaut, moindre
#   portée, sur assets, deals, tasks, forms et tickets.
#   Toutes les colonnes sont désormais mises à jour. Pour les colonnes
#   descriptives, une valeur vide de l'API n'écrase pas une valeur connue
#   (COALESCE) ; les colonnes d'état (status, dates de déploiement, de
#   clôture...) gardent l'affectation directe, comme avant.
# - clients : nouvelle colonne contact_json (objet contact complet de l'API),
#   pour retrouver le second mobile que DELTA ne lisait pas.
# - Un élément sans identifiant était compté comme une erreur : un seul
#   suffisait à bloquer le watermark à vie. Il est désormais compté à part
#   (« ignorés ») et n'empêche plus le watermark d'avancer.

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
                asset_id           = COALESCE(EXCLUDED.asset_id,          silver.upya_assets.asset_id),
                serial_number      = COALESCE(EXCLUDED.serial_number,     silver.upya_assets.serial_number),
                product_reference  = COALESCE(EXCLUDED.product_reference, silver.upya_assets.product_reference),
                batch_number       = COALESCE(EXCLUDED.batch_number,      silver.upya_assets.batch_number),
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
            ALTER TABLE silver.upya_clients
                ADD COLUMN IF NOT EXISTS contact_json JSONB;
        """,
        "upsert_sql": """
            INSERT INTO silver.upya_clients (
                client_number, status, first_name, last_name,
                gender, mobile, village, district, region,
                country, entry_date, contact_json
            ) VALUES %s
            ON CONFLICT (client_number) DO UPDATE SET
                status       = EXCLUDED.status,
                first_name   = COALESCE(NULLIF(TRIM(EXCLUDED.first_name), ''), silver.upya_clients.first_name),
                last_name    = COALESCE(NULLIF(TRIM(EXCLUDED.last_name),  ''), silver.upya_clients.last_name),
                gender       = COALESCE(EXCLUDED.gender,       silver.upya_clients.gender),
                mobile       = COALESCE(NULLIF(TRIM(EXCLUDED.mobile), ''), silver.upya_clients.mobile),
                village      = COALESCE(EXCLUDED.village,      silver.upya_clients.village),
                district     = COALESCE(EXCLUDED.district,     silver.upya_clients.district),
                region       = COALESCE(EXCLUDED.region,       silver.upya_clients.region),
                country      = COALESCE(EXCLUDED.country,      silver.upya_clients.country),
                entry_date   = COALESCE(EXCLUDED.entry_date,   silver.upya_clients.entry_date),
                contact_json = COALESCE(EXCLUDED.contact_json, silver.upya_clients.contact_json),
                updated_at   = NOW();
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
                deal_name         = COALESCE(EXCLUDED.deal_name,       silver.upya_deals.deal_name),
                type              = COALESCE(EXCLUDED.type,            silver.upya_deals.type),
                pricing_days      = COALESCE(EXCLUDED.pricing_days,    silver.upya_deals.pricing_days),
                pricing_upfront   = COALESCE(EXCLUDED.pricing_upfront, silver.upya_deals.pricing_upfront),
                set_up_on         = COALESCE(EXCLUDED.set_up_on,       silver.upya_deals.set_up_on),
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
                task_number           = COALESCE(EXCLUDED.task_number,           silver.upya_tasks.task_number),
                instructions          = COALESCE(EXCLUDED.instructions,          silver.upya_tasks.instructions),
                assigned_on           = COALESCE(EXCLUDED.assigned_on,           silver.upya_tasks.assigned_on),
                due_on                = COALESCE(EXCLUDED.due_on,                silver.upya_tasks.due_on),
                assigned_to_last_name = COALESCE(EXCLUDED.assigned_to_last_name, silver.upya_tasks.assigned_to_last_name),
                contract_number       = COALESCE(EXCLUDED.contract_number,       silver.upya_tasks.contract_number),
                client_number         = COALESCE(EXCLUDED.client_number,         silver.upya_tasks.client_number),
                parent_ticket         = COALESCE(EXCLUDED.parent_ticket,         silver.upya_tasks.parent_ticket),
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
                survey             = EXCLUDED.survey,
                paid               = EXCLUDED.paid,
                contract_number    = COALESCE(EXCLUDED.contract_number,  silver.upya_forms.contract_number),
                client_number      = COALESCE(EXCLUDED.client_number,    silver.upya_forms.client_number),
                collector_number   = COALESCE(EXCLUDED.collector_number, silver.upya_forms.collector_number),
                collector_name     = COALESCE(EXCLUDED.collector_name,   silver.upya_forms.collector_name),
                credit_agent_ref   = COALESCE(EXCLUDED.credit_agent_ref, silver.upya_forms.credit_agent_ref),
                form_date          = COALESCE(EXCLUDED.form_date,        silver.upya_forms.form_date),
                created_at_src     = COALESCE(EXCLUDED.created_at_src,   silver.upya_forms.created_at_src),
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
                status          = EXCLUDED.status,
                progress        = EXCLUDED.progress,
                updated_at_src  = EXCLUDED.updated_at_src,
                ticket_number   = COALESCE(EXCLUDED.ticket_number,   silver.upya_tickets.ticket_number),
                title           = COALESCE(EXCLUDED.title,           silver.upya_tickets.title),
                contract_number = COALESCE(EXCLUDED.contract_number, silver.upya_tickets.contract_number),
                client_number   = COALESCE(EXCLUDED.client_number,   silver.upya_tickets.client_number),
                origin          = COALESCE(EXCLUDED.origin,          silver.upya_tickets.origin),
                created_at_src  = COALESCE(EXCLUDED.created_at_src,  silver.upya_tickets.created_at_src),
                updated_at      = NOW();
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
        json.dumps(contact, ensure_ascii=False, default=str) if contact else None,
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
    total_ignores = 0   # v2 : éléments sans identifiant, sans effet sur le watermark
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
                    total_ignores += 1

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

    if total_ignores:
        logger.warning(f"{total_ignores} élément(s) sans identifiant ignoré(s) ({entity_name})")

    duration = time.time() - start_time
    logger.info(f"TERMINE v2 — {entity_name.upper()} : {total_rows:,} lignes / {total_errors} erreurs / {total_ignores} ignorés / {duration:.1f}s")

    conn.close()
    return total_rows


if __name__ == "__main__":
    entities = sys.argv[1:] if len(sys.argv) > 1 else list(ENTITIES.keys())
    for entity in entities:
        load_entity(entity)
