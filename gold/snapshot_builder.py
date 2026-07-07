# gold/snapshot_builder.py
#
# RÔLE : Créer une photo quotidienne du portefeuille
# depuis gold.unified_contracts vers gold.unified_snapshot
#
# POURQUOI UN SNAPSHOT ?
# La vue gold.unified_contracts est dynamique — elle reflète
# l'état actuel. Pour analyser l'évolution dans le temps
# ("comment était le portefeuille en mars ?"), on a besoin
# de photos horodatées.
#
# USAGE :
#   python gold/snapshot_builder.py          → snapshot aujourd'hui
#   python gold/snapshot_builder.py 2026-07-01 → snapshot date précise

import os
import sys
import logging
import time
from datetime import date, datetime, timezone

from dotenv import load_dotenv

sys.path.append(os.path.join(os.path.dirname(__file__), '..'))
from database.db_client import get_db_connection, init_schemas

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS gold.unified_snapshot (
    -- Date de la photo
    snapshot_date           DATE NOT NULL,

    -- Identifiant contrat
    contract_number         TEXT NOT NULL,

    -- Segmentation
    entite                  TEXT,
    source                  TEXT,
    categorie               TEXT,

    -- Statut à la date du snapshot
    contract_status         TEXT,
    deal_type               TEXT,
    paid_off                TEXT,

    -- Financier à la date du snapshot
    total_contract_value    NUMERIC(18,2),
    total_paid              NUMERIC(18,2),
    remaining_debt          NUMERIC(18,2),

    -- Retard à la date du snapshot
    consecutive_locked_days INTEGER,

    -- Localisation
    region                  TEXT,

    -- Métadonnées
    created_at              TIMESTAMPTZ DEFAULT NOW(),

    -- Clé primaire composite : un contrat par jour
    PRIMARY KEY (snapshot_date, contract_number)
);

CREATE INDEX IF NOT EXISTS idx_snapshot_date
    ON gold.unified_snapshot(snapshot_date);
CREATE INDEX IF NOT EXISTS idx_snapshot_categorie
    ON gold.unified_snapshot(categorie);
CREATE INDEX IF NOT EXISTS idx_snapshot_status
    ON gold.unified_snapshot(contract_status);
"""

# Table d'audit des snapshots
CREATE_AUDIT_SQL = """
CREATE TABLE IF NOT EXISTS gold.snapshot_audit (
    id              SERIAL PRIMARY KEY,
    snapshot_date   DATE NOT NULL,
    run_at          TIMESTAMPTZ DEFAULT NOW(),
    rows_inserted   INTEGER,
    duration_sec    NUMERIC(10,2),
    status          TEXT
);
"""


def build_snapshot(snapshot_date=None):
    """
    Crée le snapshot du portefeuille pour une date donnée.

    Logique :
    1. Supprime le snapshot existant pour cette date (idempotent)
    2. Insère une copie de gold.unified_contracts horodatée
    3. Enregistre dans l'audit

    Args:
        snapshot_date: date au format 'YYYY-MM-DD' ou None (= aujourd'hui)
    """
    load_dotenv()
    start_time = time.time()

    if snapshot_date is None:
        snap_date = date.today()
    else:
        snap_date = date.fromisoformat(snapshot_date)

    logger.info("=" * 50)
    logger.info(f"SNAPSHOT BUILDER — {snap_date}")
    logger.info("=" * 50)

    conn = get_db_connection()
    init_schemas(conn)
    cur = conn.cursor()

    # Création des tables si nécessaire
    cur.execute(CREATE_TABLE_SQL)
    cur.execute(CREATE_AUDIT_SQL)
    conn.commit()
    logger.info("Tables snapshot prêtes")

    # Suppression du snapshot existant pour cette date
    # (permet de rejouer idempotent)
    cur.execute("""
        SELECT COUNT(*) FROM gold.unified_snapshot
        WHERE snapshot_date = %s
    """, (snap_date,))
    existing = cur.fetchone()[0]

    if existing > 0:
        logger.info(f"Snapshot existant ({existing:,} lignes) → suppression...")
        cur.execute("""
            DELETE FROM gold.unified_snapshot
            WHERE snapshot_date = %s
        """, (snap_date,))
        conn.commit()

    # Insertion depuis la vue Gold
    # On copie l'état actuel de unified_contracts avec la date du snapshot
    logger.info(f"Insertion snapshot depuis gold.unified_contracts...")
    cur.execute("""
        INSERT INTO gold.unified_snapshot (
            snapshot_date,
            contract_number,
            entite,
            source,
            categorie,
            contract_status,
            deal_type,
            paid_off,
            total_contract_value,
            total_paid,
            remaining_debt,
            consecutive_locked_days,
            region
        )
        SELECT
            %s::DATE,
            contract_number,
            entite,
            source,
            categorie,
            contract_status,
            deal_type,
            paid_off,
            total_contract_value,
            total_paid,
            remaining_debt,
            consecutive_locked_days,
            region
        FROM gold.unified_contracts
        WHERE contract_status NOT IN ('CANCELLED')
    """, (snap_date,))

    rows_inserted = cur.rowcount
    conn.commit()

    duration = time.time() - start_time

    # Enregistrement audit
    cur.execute("""
        INSERT INTO gold.snapshot_audit
            (snapshot_date, rows_inserted, duration_sec, status)
        VALUES (%s, %s, %s, 'success')
    """, (snap_date, rows_inserted, round(duration, 2)))
    conn.commit()

    # Statistiques du snapshot
    cur.execute("""
        SELECT
            categorie,
            contract_status,
            COUNT(*) as nb,
            ROUND(SUM(total_contract_value)/1e9, 2) as valeur_mrd,
            ROUND(SUM(total_paid)/1e9, 2) as paid_mrd,
            ROUND(SUM(total_paid)/NULLIF(SUM(total_contract_value),0)*100, 1) as cr
        FROM gold.unified_snapshot
        WHERE snapshot_date = %s
        GROUP BY categorie, contract_status
        ORDER BY categorie, nb DESC
    """, (snap_date,))

    rows = cur.fetchall()
    logger.info(f"\n{'CATEGORIE':15} | {'STATUT':12} | {'NB':>7} | {'VALEUR':>8} | {'PAYÉ':>8} | {'CR':>6}")
    logger.info("-" * 70)
    for row in rows:
        cr = f"{row[5]}%" if row[5] else "N/A"
        logger.info(
            f"{str(row[0]):15} | {str(row[1]):12} | {row[2]:>7,} | "
            f"{str(row[3]):>8} | {str(row[4]):>8} | {cr:>6}"
        )

    # Total global
    cur.execute("""
        SELECT COUNT(*), 
               ROUND(SUM(total_contract_value)/1e9, 2),
               ROUND(SUM(total_paid)/1e9, 2)
        FROM gold.unified_snapshot
        WHERE snapshot_date = %s
    """, (snap_date,))
    tot = cur.fetchone()

    cur.close()
    conn.close()

    logger.info("=" * 50)
    logger.info(f"✅ SNAPSHOT {snap_date} TERMINÉ")
    logger.info(f"   Contrats : {rows_inserted:,}")
    logger.info(f"   Valeur   : {tot[1]} Mrd XOF")
    logger.info(f"   Encaissé : {tot[2]} Mrd XOF")
    logger.info(f"   Durée    : {duration:.1f}s")
    logger.info("=" * 50)

    return rows_inserted


def list_snapshots():
    """Affiche la liste des snapshots disponibles."""
    load_dotenv()
    conn = get_db_connection()
    cur  = conn.cursor()
    cur.execute("""
        SELECT snapshot_date, COUNT(*) as contrats,
               ROUND(SUM(total_paid)/1e9, 2) as paid_mrd,
               run_at
        FROM gold.unified_snapshot s
        JOIN gold.snapshot_audit a USING (snapshot_date)
        GROUP BY snapshot_date, run_at
        ORDER BY snapshot_date DESC
        LIMIT 10
    """)
    rows = cur.fetchall()
    if not rows:
        print("Aucun snapshot disponible.")
    else:
        print(f"\n{'DATE':12} | {'CONTRATS':>8} | {'PAYÉ Mrd':>8} | {'CRÉÉ LE'}")
        print("-" * 55)
        for row in rows:
            print(f"{str(row[0]):12} | {row[1]:>8,} | {str(row[2]):>8} | {row[3]}")
    cur.close()
    conn.close()


if __name__ == "__main__":
    if len(sys.argv) > 1:
        if sys.argv[1] == "list":
            list_snapshots()
        else:
            build_snapshot(sys.argv[1])
    else:
        build_snapshot()