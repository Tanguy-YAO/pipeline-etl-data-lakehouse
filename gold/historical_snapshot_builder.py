# gold/historical_snapshot_builder.py
#
# RÔLE : Reconstruire les snapshots historiques mensuels
# depuis silver.surge_lease_engine + silver.upya_contracts
#
# LOGIQUE :
#   Pour chaque mois M depuis avril 2024 :
#   - SURGE : prendre la dernière ligne du lease_engine
#             où posting_date <= fin du mois M
#             → total_cash_collected = total_paid à cette date
#             → ending_principal = remaining_debt
#   - UPYA  : snapshot statique (on n'a pas l'historique UPYA)
#             → on insère avec les valeurs actuelles Silver
#
# USAGE :
#   python gold/historical_snapshot_builder.py
#   python gold/historical_snapshot_builder.py 2024-04 2026-06

import os
import sys
import logging
import time
from datetime import date, datetime
from dateutil.relativedelta import relativedelta

from dotenv import load_dotenv

sys.path.append(os.path.join(os.path.dirname(__file__), '..'))
from database.db_client import get_db_connection, init_schemas

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


def get_month_end(year, month):
    """Retourne le dernier jour du mois."""
    first_next = date(year + (month // 12), (month % 12) + 1, 1)
    return first_next - __import__('datetime').timedelta(days=1)


def build_historical_snapshot(start_month="2024-04", end_month=None):
    """
    Construit les snapshots mensuels historiques.

    Pour SURGE : utilise silver.surge_lease_engine
    Pour UPYA  : utilise silver.upya_contracts (état actuel)

    Args:
        start_month : "YYYY-MM" — mois de départ (défaut: avril 2024)
        end_month   : "YYYY-MM" — mois de fin (défaut: mois dernier)
    """
    load_dotenv()
    start_time = time.time()

    # Calcul des mois à traiter
    start = datetime.strptime(start_month + "-01", "%Y-%m-%d").date()
    if end_month:
        end = datetime.strptime(end_month + "-01", "%Y-%m-%d").date()
    else:
        today = date.today()
        end   = date(today.year, today.month, 1) - __import__('datetime').timedelta(days=1)
        end   = date(end.year, end.month, 1)

    # Liste des mois
    months = []
    current = start
    while current <= end:
        months.append(current)
        current = current + relativedelta(months=1)

    logger.info("=" * 55)
    logger.info("HISTORICAL SNAPSHOT BUILDER")
    logger.info(f"Période : {start_month} → {end.strftime('%Y-%m')}")
    logger.info(f"Mois à traiter : {len(months)}")
    logger.info("=" * 55)

    conn = get_db_connection()
    init_schemas(conn)

    # Créer la table snapshot si nécessaire
    cur = conn.cursor()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS gold.unified_snapshot (
            snapshot_date           DATE NOT NULL,
            contract_number         TEXT NOT NULL,
            entite                  TEXT,
            source                  TEXT,
            categorie               TEXT,
            contract_status         TEXT,
            deal_type               TEXT,
            paid_off                TEXT,
            total_contract_value    NUMERIC(18,2),
            total_paid              NUMERIC(18,2),
            remaining_debt          NUMERIC(18,2),
            consecutive_locked_days INTEGER,
            region                  TEXT,
            created_at              TIMESTAMPTZ DEFAULT NOW(),
            PRIMARY KEY (snapshot_date, contract_number)
        );
        CREATE INDEX IF NOT EXISTS idx_snapshot_date
            ON gold.unified_snapshot(snapshot_date);
        CREATE INDEX IF NOT EXISTS idx_snapshot_categorie
            ON gold.unified_snapshot(categorie);
    """)
    conn.commit()
    cur.close()

    total_inserted = 0

    for snap_month in months:
        month_end = get_month_end(snap_month.year, snap_month.month)
        snap_date = month_end  # On prend le dernier jour du mois

        logger.info(f"\n--- Snapshot {snap_date} ---")

        # Vérifier si le snapshot existe déjà
        cur = conn.cursor()
        cur.execute(
            "SELECT COUNT(*) FROM gold.unified_snapshot WHERE snapshot_date = %s",
            (snap_date,)
        )
        existing = cur.fetchone()[0]
        if existing > 0:
            logger.info(f"  Snapshot existant ({existing:,} lignes) → ignoré")
            cur.close()
            continue
        cur.close()

        # ============================================================
        # SURGE : depuis le lease_engine
        # Pour chaque contrat, on prend la dernière ligne
        # où posting_date <= fin du mois
        # ============================================================
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO gold.unified_snapshot (
                snapshot_date, contract_number,
                entite, source, categorie,
                contract_status, deal_type, paid_off,
                total_contract_value, total_paid, remaining_debt,
                region
            )
            WITH latest_lbl AS (
                -- Dernière ligne lease_engine par contrat <= fin du mois
                SELECT DISTINCT ON (le.installation_id)
                    le.installation_id,
                    le.total_cash_collected,
                    le.ending_principal,
                    le.total_ending_balance,
                    le.posting_date
                FROM silver.surge_lease_engine le
                WHERE le.installation_id IS NOT NULL
                  AND le.posting_date <= %s
                ORDER BY le.installation_id, le.posting_date DESC
            ),
            surge_snap AS (
                SELECT
                    sc.installation_id          AS contract_number,
                    'SURGE'                     AS entite,
                    'SURGE'                     AS source,
                    CASE
                        WHEN sc.installation_id IN (
                            SELECT contract_number FROM silver.surge_neotci_list
                        ) THEN 'surge_neotci'
                        WHEN sc.paid_at >= '2024-04-01' THEN 'surge_tevia'
                        ELSE 'surge_zeci'
                    END                         AS categorie,
                    sc.status                   AS contract_status,
                    COALESCE(pl.deal_type, 'PAYG') AS deal_type,
                    'false'                     AS paid_off,
                    pl.total_contract_value,
                    COALESCE(ll.total_cash_collected, 0) AS total_paid,
                    COALESCE(ll.ending_principal, pl.total_contract_value) AS remaining_debt,
                    sc.region
                FROM silver.surge_contracts sc
                LEFT JOIN latest_lbl ll
                    ON ll.installation_id = sc.installation_id::TEXT
                LEFT JOIN silver.surge_product_lookup pl
                    ON pl.installation_id = sc.installation_id::TEXT
                WHERE sc.activated_at IS NOT NULL
            )
            SELECT %s, * FROM surge_snap
        """, (snap_date, snap_date))

        surge_rows = cur.rowcount
        conn.commit()
        logger.info(f"  SURGE : {surge_rows:,} contrats")

        # ============================================================
        # UPYA : depuis silver.upya_contracts (état actuel)
        # On n'a pas l'historique UPYA donc on utilise les valeurs
        # actuelles — c'est une approximation pour l'historique
        # ============================================================
        cur.execute("""
            INSERT INTO gold.unified_snapshot (
                snapshot_date, contract_number,
                entite, source, categorie,
                contract_status, deal_type, paid_off,
                total_contract_value, total_paid, remaining_debt,
                region
            )
            SELECT
                %s,
                c.contract_number,
                CASE
                    WHEN c.entity_name IN ('TEVIA', 'GREENO') THEN c.entity_name
                    ELSE 'TEVIA'
                END,
                'UPYA',
                'upya_tevia',
                UPPER(TRIM(c.status)),
                COALESCE(c.deal_type, 'PAYG'),
                CASE
                    WHEN LOWER(TRIM(c.paid_off_status)) IN ('yes','true','1')
                    THEN 'true' ELSE 'false'
                END,
                c.total_cost,
                c.total_paid,
                c.remaining_debt,
                c.region
            FROM silver.upya_contracts c
            WHERE c.contract_number IS NOT NULL
              AND c.signing_date IS NOT NULL
              AND c.signing_date <= %s
            ON CONFLICT (snapshot_date, contract_number) DO NOTHING
        """, (snap_date, snap_date))

        upya_rows = cur.rowcount
        conn.commit()
        cur.close()

        month_total = surge_rows + upya_rows
        total_inserted += month_total
        logger.info(f"  UPYA  : {upya_rows:,} contrats")
        logger.info(f"  Total : {month_total:,} contrats")

    duration = time.time() - start_time

    # Résumé final
    conn2 = get_db_connection()
    cur2  = conn2.cursor()
    cur2.execute("""
        SELECT snapshot_date, COUNT(*),
               ROUND(SUM(total_paid)/1e9, 2)
        FROM gold.unified_snapshot
        WHERE snapshot_date >= %s
        GROUP BY snapshot_date
        ORDER BY snapshot_date
    """, (date.fromisoformat(start_month + "-01"),))

    rows = cur2.fetchall()
    logger.info("\n" + "=" * 55)
    logger.info("SNAPSHOTS HISTORIQUES CRÉÉS")
    logger.info(f"{'DATE':12} | {'CONTRATS':>8} | {'ENCAISSÉ Mrd':>12}")
    logger.info("-" * 40)
    for row in rows:
        logger.info(f"{str(row[0]):12} | {row[1]:>8,} | {str(row[2]):>12}")

    cur2.close()
    conn2.close()
    conn.close()

    logger.info("=" * 55)
    logger.info(f"✅ HISTORIQUE TERMINÉ")
    logger.info(f"   Mois traités : {len(months)}")
    logger.info(f"   Lignes total : {total_inserted:,}")
    logger.info(f"   Durée        : {duration:.1f}s")
    logger.info("=" * 55)


if __name__ == "__main__":
    # Usage: python historical_snapshot_builder.py [start_month] [end_month]
    # Ex:    python historical_snapshot_builder.py 2024-04 2026-06
    start = sys.argv[1] if len(sys.argv) > 1 else "2024-04"
    end   = sys.argv[2] if len(sys.argv) > 2 else None
    build_historical_snapshot(start, end)