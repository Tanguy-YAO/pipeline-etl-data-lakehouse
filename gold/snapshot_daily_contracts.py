"""
gold/snapshot_daily_contracts.py
Prend un snapshot quotidien de gold.unified_contracts et l'insère dans
gold.unified_daily_snapshot (une ligne par contrat par jour).

Usage
    python gold/snapshot_daily_contracts.py              # date = aujourd'hui
    python gold/snapshot_daily_contracts.py --date 2026-10-09   # date forcée
    python gold/snapshot_daily_contracts.py --force      # réécrit si déjà présent

Prérequis
    Variable d'environnement DATABASE_URL (format psycopg2) :
        postgresql://user:password@host:port/dbname
    ou configurer les variables individuelles DB_HOST, DB_PORT, DB_NAME,
    DB_USER, DB_PASSWORD.

Table cible (créer une fois si absente) :
    CREATE TABLE IF NOT EXISTS gold.unified_daily_snapshot (
        snapshot_date           date        NOT NULL,
        contract_number         bigint,
        entite                  text,
        source                  text,
        categorie               text,
        client_number           text,
        registration_date       timestamptz,
        paid_off_date           date,
        repossession_date       date,
        product_name            text,
        deal_type               text,
        total_contract_value    numeric,
        upfront_payment         numeric,
        monthly_payment         numeric,
        total_paid              numeric,
        remaining_debt          numeric,
        contract_status         text,
        paid_off                boolean,
        consecutive_locked_days numeric,
        region                  text,
        sub_prefecture          text,
        computed_at             timestamptz,
        PRIMARY KEY (snapshot_date, contract_number)
    );
"""

import argparse
import logging
import os
import sys
from datetime import date, datetime

import psycopg2
import psycopg2.extras

from dotenv import load_dotenv
load_dotenv()  # Charger les variables d'environnement depuis .env si présent

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S,%f"[:-3],
)
log = logging.getLogger(__name__)


# Connexion

def get_conn():
    url = os.getenv("DATABASE_URL")
    if url:
        return psycopg2.connect(url)
    return psycopg2.connect(
        host=os.getenv("DB_HOST", "localhost"),
        port=int(os.getenv("DB_PORT", 5432)),
        dbname=os.getenv("DB_NAME"),
        user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD"),
    )


# Colonnes à snapshoter

COLUMNS = [
    "contract_number",
    "entite",
    "source",
    "categorie",
    "client_number",
    "registration_date",
    "paid_off_date",
    "repossession_date",
    "product_name",
    "deal_type",
    "total_contract_value::numeric",
    "upfront_payment::numeric",
    "monthly_payment::numeric",
    "total_paid::numeric",
    "remaining_debt::numeric",
    "contract_status",
    "paid_off",
    "consecutive_locked_days",
    "region",
    "sub_prefecture",
    "computed_at",
]

# Noms des colonnes cibles (sans le cast)
TARGET_COLS = [c.split("::")[0] for c in COLUMNS]


# Logique principale

def run_snapshot(target_date: date, force: bool = False):
    log.info("Snapshot cible : %s", target_date)

    # FIX 1 : conn est maintenant à l'intérieur du try.
    # Si get_conn() échoue (réseau, credentials), l'erreur est loggée
    # par le except ci-dessous au lieu de remonter silencieusement.
    try:
        conn = get_conn()
        conn.autocommit = False

        try:
            with conn.cursor() as cur:

                # Vérifier si le snapshot existe déjà
                cur.execute(
                    "SELECT COUNT(*) FROM gold.unified_daily_snapshot WHERE snapshot_date = %s",
                    (target_date,),
                )
                existing = cur.fetchone()[0]

                if existing > 0 and not force:
                    log.info(
                        "Snapshot du %s déjà présent (%s lignes). Rien à faire.",
                        target_date, existing,
                    )
                    return

                if existing > 0 and force:
                    log.info(
                        "Snapshot du %s déjà présent (%s lignes). --force : suppression.",
                        target_date, existing,
                    )
                    cur.execute(
                        "DELETE FROM gold.unified_daily_snapshot WHERE snapshot_date = %s",
                        (target_date,),
                    )

                # Lecture depuis gold.unified_contracts
                log.info("Lecture de gold.unified_contracts…")
                select_sql = "SELECT {cols} FROM gold.unified_contracts".format(
                    cols=", ".join(COLUMNS)
                )
                cur.execute(select_sql)
                rows = cur.fetchall()
                log.info("%s contrats lus.", len(rows))

                if not rows:
                    log.warning("Aucun contrat lu — snapshot non inséré.")
                    return

                # Insertion en batch
                insert_sql = """
                    INSERT INTO gold.unified_daily_snapshot
                        (snapshot_date, {cols})
                    VALUES %s
                    ON CONFLICT (snapshot_date, contract_number) DO NOTHING
                """.format(cols=", ".join(TARGET_COLS))

                # Préfixer chaque ligne avec la date snapshot
                data = [(target_date,) + row for row in rows]

                psycopg2.extras.execute_values(cur, insert_sql, data, page_size=2000)
                conn.commit()
                log.info("Snapshot %s inséré : %s lignes.", target_date, len(rows))

                # Log dans bronze_meta.run_log
                cur.execute(
                    """
                    INSERT INTO bronze_meta.run_log
                        (source, entity, status, rows_count, run_at, run_date)
                    VALUES ('gold', 'unified_daily_snapshot', 'success', %s, NOW(), CURRENT_DATE)
                    """,
                    (len(rows),),
                )
                conn.commit()

        except Exception as exc:
            conn.rollback()
            log.error("Erreur snapshot : %s", exc)

            # Tenter quand même de logger l'échec
            try:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        INSERT INTO bronze_meta.run_log
                            (source, entity, status, rows_count, run_at, run_date)
                        VALUES ('gold', 'unified_daily_snapshot', 'error', 0, NOW(), CURRENT_DATE)
                        """,
                    )
                conn.commit()
            except Exception:
                pass

            raise

        finally:
            conn.close()

    except Exception as exc:
        # FIX 2 : toute exception (y compris échec get_conn) est loggée ici
        # avant de remonter au __main__.
        log.error("Échec critique run_snapshot : %s", exc)
        raise


# Entrée

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Snapshot quotidien gold.unified_contracts")
    parser.add_argument(
        "--date",
        type=lambda s: datetime.strptime(s, "%Y-%m-%d").date(),
        default=date.today(),
        help="Date du snapshot (défaut : aujourd'hui, format YYYY-MM-DD)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Supprimer et réécrire si le snapshot existe déjà",
    )
    args = parser.parse_args()

    try:
        run_snapshot(target_date=args.date, force=args.force)
    except Exception as e:
        sys.exit(1)