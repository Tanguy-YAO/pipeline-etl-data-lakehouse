
# database/db_client.py
# Brique de connexion PostgreSQL — couches Silver & Gold

import os
import logging
from contextlib import contextmanager

import psycopg2
from psycopg2.extras import execute_values
from dotenv import load_dotenv

logger = logging.getLogger(__name__)


def get_db_connection(autocommit=False):
    """
    Crée et retourne une connexion PostgreSQL.

    Analogie : c'est comme décrocher le téléphone et composer
    le numéro de PostgreSQL. La connexion reste ouverte jusqu'à
    ce que tu la fermes explicitement.

    Args:
        autocommit: si True, chaque requête est commitée
        immédiatement. Si False (défaut), tu gères toi-même
        les commit() et rollback().
    """
    load_dotenv()

    host     = os.getenv("DB_HOST")
    port     = int(os.getenv("DB_PORT", "5432"))
    dbname   = os.getenv("DB_NAME", "railway")
    user     = os.getenv("DB_USER", "postgres")
    password = os.getenv("DB_PASSWORD")

    missing = [k for k, v in {
        "DB_HOST": host,
        "DB_PASSWORD": password,
    }.items() if not v]

    if missing:
        raise ValueError(f"Variables manquantes dans .env : {missing}")

    conn = psycopg2.connect(
        host=host,
        port=port,
        dbname=dbname,
        user=user,
        password=password,
        sslmode="require",    # Obligatoire pour Railway (connexion publique)
        connect_timeout=30,
    )
    conn.autocommit = autocommit

    logger.info(f"Connexion PostgreSQL → {host}:{port}/{dbname}")
    return conn


@contextmanager
def get_db_cursor(autocommit=False):
    """
    Gestionnaire de contexte pour connexion + curseur.

    Analogie : c'est comme un distributeur automatique —
    tu insères ta carte (ouverture), tu fais ton opération,
    et la carte est rendue automatiquement (fermeture),
    même si une erreur survient.

    Utilisation :
        with get_db_cursor() as (conn, cur):
            cur.execute("SELECT 1")
            conn.commit()

    Le 'with' garantit que connexion et curseur sont TOUJOURS
    fermés proprement, même si une exception survient.
    """
    conn = None
    cur  = None
    try:
        conn = get_db_connection(autocommit=autocommit)
        cur  = conn.cursor()
        yield conn, cur
    except Exception:
        if conn and not autocommit:
            conn.rollback()
            logger.warning("Rollback effectué")
        raise
    finally:
        # Ce bloc s'exécute TOUJOURS — erreur ou pas
        if cur:
            cur.close()
        if conn:
            conn.close()
            logger.info("Connexion PostgreSQL fermée")


def init_schemas(conn):
    """
    Crée les schémas Silver, Gold et Bronze Meta.

    Les schémas PostgreSQL sont comme des tiroirs dans
    une armoire. On organise les tables par rôle :

        silver.*      → données propres et typées
        gold.*        → KPIs et agrégats pour Metabase
        bronze_meta.* → journal de traçabilité des runs

    Idempotent : peut être appelé plusieurs fois sans risque.
    """
    cur = conn.cursor()
    try:
        cur.execute("CREATE SCHEMA IF NOT EXISTS silver;")
        cur.execute("CREATE SCHEMA IF NOT EXISTS gold;")
        cur.execute("CREATE SCHEMA IF NOT EXISTS bronze_meta;")
        conn.commit()
        logger.info("Schémas créés : silver, gold, bronze_meta")
    except Exception as e:
        conn.rollback()
        logger.error(f"Erreur création schémas : {e}")
        raise
    finally:
        cur.close()


def init_run_log(conn):
    """
    Crée la table de traçabilité des runs Bronze.

    On ne stocke PAS les données brutes dans PostgreSQL
    (elles restent dans MinIO). Mais on trace ici :
    - QUAND chaque extraction a eu lieu
    - COMBIEN de lignes ont été traitées
    - QUEL est le chemin MinIO des fichiers déposés

    C'est notre registre de runs — indispensable pour
    le chargement incrémental (savoir depuis quand
    on doit repartir).
    """
    cur = conn.cursor()
    try:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS bronze_meta.run_log (
                id            SERIAL PRIMARY KEY,
                source        TEXT NOT NULL,
                entity        TEXT NOT NULL,
                run_date      DATE NOT NULL,
                run_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                status        TEXT NOT NULL,
                pages_fetched INTEGER,
                rows_count    INTEGER,
                minio_prefix  TEXT,
                error_message TEXT,
                duration_sec  NUMERIC(10,2)
            );
        """)
        cur.execute("""
            CREATE INDEX IF NOT EXISTS idx_run_log_source_entity
            ON bronze_meta.run_log(source, entity, run_date);
        """)
        conn.commit()
        logger.info("Table bronze_meta.run_log prête")
    except Exception as e:
        conn.rollback()
        logger.error(f"Erreur création run_log : {e}")
        raise
    finally:
        cur.close()


def log_run(conn, source, entity, status,
            pages_fetched=0, rows_count=0,
            minio_prefix="", error_message=None,
            duration_sec=0.0):
    """
    Enregistre un run dans bronze_meta.run_log.

    Appelé par chaque extracteur à la fin de son exécution.
    Exemple : après avoir extrait 500 paiements UPYA,
    on enregistre : source=upya, entity=payments,
    status=success, rows_count=500.
    """
    from datetime import date
    cur = conn.cursor()
    try:
        cur.execute("""
            INSERT INTO bronze_meta.run_log
                (source, entity, run_date, status,
                 pages_fetched, rows_count, minio_prefix,
                 error_message, duration_sec)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
            RETURNING id;
        """, (
            source, entity, date.today(), status,
            pages_fetched, rows_count, minio_prefix,
            error_message, round(duration_sec, 2)
        ))
        run_id = cur.fetchone()[0]
        conn.commit()
        logger.info(f"Run loggé → id={run_id} | {source}/{entity} | {status}")
        return run_id
    except Exception as e:
        conn.rollback()
        logger.error(f"Erreur log_run : {e}")
        raise
    finally:
        cur.close()


def get_last_successful_run(conn, source, entity):
    """
    Retourne le dernier run réussi pour une source/entité.

    C'est le mécanisme clé du chargement incrémental :
    'Quelle est la dernière fois que j'ai extrait les
    payments UPYA ? Je ne tire que ce qui a changé depuis.'

    Returns:
        dict avec run_date, rows_count, minio_prefix
        ou None si aucun run précédent
    """
    cur = conn.cursor()
    try:
        cur.execute("""
            SELECT run_date, rows_count, minio_prefix, run_at
            FROM bronze_meta.run_log
            WHERE source = %s
              AND entity = %s
              AND status = 'success'
            ORDER BY run_at DESC
            LIMIT 1;
        """, (source, entity))

        row = cur.fetchone()
        if not row:
            return None
        return {
            "run_date":    row[0],
            "rows_count":  row[1],
            "minio_prefix": row[2],
            "run_at":      row[3],
        }
    finally:
        cur.close()



# TEST — python database/db_client.py

if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s"
    )

    print("\n=== TEST CONNEXION POSTGRESQL ===\n")

    # Test 1 : connexion simple
    conn = get_db_connection()
    cur  = conn.cursor()
    cur.execute("SELECT version();")
    version = cur.fetchone()[0]
    print(f"✅ Connexion OK !")
    print(f"   Version : {version[:60]}...")
    cur.close()
    conn.close()

    # Test 2 : context manager
    print("\n--- Test context manager ---")
    with get_db_cursor() as (conn, cur):
        cur.execute("SELECT current_database(), current_user;")
        db, user = cur.fetchone()
        print(f"✅ Base : {db} | Utilisateur : {user}")

    # Test 3 : init schémas
    print("\n--- Init schémas ---")
    conn = get_db_connection()
    init_schemas(conn)
    init_run_log(conn)
    conn.close()

    # Test 4 : log d'un run
    print("\n--- Test log_run ---")
    conn = get_db_connection()
    run_id = log_run(
        conn,
        source="test",
        entity="ping",
        status="success",
        rows_count=42,
        duration_sec=1.5,
        minio_prefix="bronze/test/ping/2026/05/26/"
    )
    print(f"✅ Run loggé avec id={run_id}")

    # Test 5 : récupération du dernier run
    last = get_last_successful_run(conn, "test", "ping")
    print(f"✅ Dernier run : {last}")
    conn.close()

    print("\n=== TEST TERMINÉ ===\n")