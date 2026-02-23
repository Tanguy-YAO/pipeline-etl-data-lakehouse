from airflow import DAG
from airflow.operators.python import PythonOperator
from datetime import datetime, timedelta
import subprocess

# Arguments par défaut pour toutes les tâches
default_args = {
    "owner": "data_engineer_tanguy",
    "depends_on_past": False,
    "retries": 3,
    "retry_delay": timedelta(minutes=5),
    "email_on_failure": False,
}

# Définition du DAG
with DAG(
    dag_id="etl_books_pipeline",
    default_args=default_args,
    description="Pipeline ETL complet : Extraction -> Silver -> Gold",
    schedule_interval="0 9 * * *",  # Tous les jours à 9h
    start_date=datetime(2026, 2, 24),
    catchup=False,
) as dag:
    # ── Fonctions à exécuter ──
    def run_scraper():
        subprocess.run(["python3", "/home/hp/projet-data-eng/extractors/extractors.scrapers_books.py"], check=True)

    def run_csv_reader():
        subprocess.run(["python3", "/home/hp/projet-data-eng/extractors/csv_reader.py"], check=True)

    def run_sql_reader():
        subprocess.run(["python3", "/home/hp/projet-data-eng/extractors/sql_reader.py"], check=True)

    def run_transform_silver():
        subprocess.run(["python3", "/home/hp/projet-data-eng/spark_jobs/transform_silver.py"], check=True)

    def run_transform_gold():
        subprocess.run(["python3", "/home/hp/projet-data-eng/spark_jobs/transform_gold.py"], check=True)

    # ── Définition des tâches ──
    task_scraper = PythonOperator(task_id="scraper_books", python_callable=run_scraper)
    task_csv     = PythonOperator(task_id="csv_reader",    python_callable=run_csv_reader)
    task_sql     = PythonOperator(task_id="sql_reader",    python_callable=run_sql_reader)
    task_silver  = PythonOperator(task_id="transform_silver", python_callable=run_transform_silver)
    task_gold    = PythonOperator(task_id="transform_gold",   python_callable=run_transform_gold)

    # ── Ordre d'exécution ──
    [task_scraper, task_csv, task_sql] >> task_silver >> task_gold