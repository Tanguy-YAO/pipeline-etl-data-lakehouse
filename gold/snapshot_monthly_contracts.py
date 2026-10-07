import os
import logging
from datetime import date, timedelta
from pathlib import Path

import psycopg2
from psycopg2.extras import execute_values
from dotenv import load_dotenv

load_dotenv(dotenv_path=Path(__file__).resolve().parent.parent / ".env")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
log = logging.getLogger(__name__)


def get_snapshot_date(force_date: date = None) -> date:
    """Dernier jour du mois précédent, sauf si une date est forcée (backfill)."""
    if force_date:
        return force_date
    today = date.today()
    first_of_month = today.replace(day=1)
    return first_of_month - timedelta(days=1)


def snapshot_exists(cur, snapshot_date: date) -> bool:
    cur.execute(
        "SELECT 1 FROM gold.contracts_monthly_snapshot WHERE snapshot_date = %s LIMIT 1",
        (snapshot_date,)
    )
    return cur.fetchone() is not None


def run_snapshot(force_date: date = None):
    snapshot_date = get_snapshot_date(force_date)
    log.info(f"Snapshot cible : {snapshot_date}")

    database_url = (
        f"postgresql://{os.environ['DB_USER']}:{os.environ['DB_PASSWORD']}"
        f"@{os.environ['DB_HOST']}:{os.environ['DB_PORT']}/{os.environ['DB_NAME']}"
    )

    conn = psycopg2.connect(database_url)
    conn.autocommit = False

    try:
        with conn.cursor() as cur:

            if snapshot_exists(cur, snapshot_date):
                log.info(f"Snapshot du {snapshot_date} déjà présent. Rien à faire.")
                return

            log.info("Lecture de gold.unified_contracts…")
            cur.execute("""
                SELECT
                    %s                       AS snapshot_date,
                    contract_number,
                    entite,
                    source,
                    categorie,
                    client_number,
                    customer_name,
                    agent_number,
                    agent_name,
                    paid_date,
                    registration_date,
                    product_name,
                    asset_number,
                    deal_type,
                    total_contract_value,
                    upfront_payment,
                    monthly_payment,
                    total_paid,
                    remaining_debt,
                    contract_status,
                    paid_off,
                    paid_off_date,
                    repossession_date,
                    last_status_update,
                    next_status_update,
                    consecutive_locked_days,
                    region,
                    sub_prefecture,
                    village,
                    latitude,
                    longitude,
                    phone_number,
                    computed_at,
                    NOW()                    AS snapshotted_at
                FROM gold.unified_contracts
            """, (snapshot_date,))

            rows = cur.fetchall()
            log.info(f"{len(rows)} contrats lus.")

            if not rows:
                log.warning("Aucun contrat trouvé dans unified_contracts. Snapshot annulé.")
                return

            insert_sql = """
                INSERT INTO gold.contracts_monthly_snapshot (
                    snapshot_date, contract_number, entite, source, categorie,
                    client_number, customer_name, agent_number, agent_name,
                    paid_date, registration_date, product_name, asset_number,
                    deal_type, total_contract_value, upfront_payment, monthly_payment,
                    total_paid, remaining_debt, contract_status, paid_off,
                    paid_off_date, repossession_date, last_status_update,
                    next_status_update, consecutive_locked_days, region,
                    sub_prefecture, village, latitude, longitude,
                    phone_number, computed_at, snapshotted_at
                )
                VALUES %s
                ON CONFLICT (snapshot_date, contract_number) DO NOTHING
            """
            execute_values(cur, insert_sql, rows, page_size=1000)
            conn.commit()
            log.info(f"Snapshot {snapshot_date} inséré avec succès : {len(rows)} lignes.")

            cur.execute("""
                INSERT INTO bronze_meta.run_log (entity, status, rows_count, run_at)
                VALUES ('contracts_monthly_snapshot', 'success', %s, NOW())
            """, (len(rows),))
            conn.commit()

    except Exception as e:
        conn.rollback()
        log.error(f"Erreur snapshot : {e}")
        try:
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO bronze_meta.run_log (entity, status, error_message, run_at)
                    VALUES ('contracts_monthly_snapshot', 'error', %s, NOW())
                """, (str(e),))
                conn.commit()
        except Exception:
            pass
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    import sys
    force = date.fromisoformat(sys.argv[1]) if len(sys.argv) > 1 else None
    run_snapshot(force_date=force)