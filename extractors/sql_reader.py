import sqlite3
import pandas as pd
import boto3
from datetime import datetime

# Chemin de la base SQLite
DB_PATH = "/home/hp/projet-data-eng/config/books_db.sqlite"


def creer_base():
    """Crée la base SQLite avec des données de catégories"""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    # Création de la table
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS categories (
            id INTEGER PRIMARY KEY,
            genre VARCHAR(50),
            description TEXT,
            nb_livres_estimes INTEGER
        )
    """)

    # Insertion des données
    categories = [
        (1, "Fiction",      "Romans et histoires imaginaires",    450000),
        (2, "Science",      "Livres scientifiques et techniques", 120000),
        (3, "Histoire",     "Livres historiques et biographies",  200000),
        (4, "Philosophie",  "Ouvrages philosophiques et essais",   80000),
        (5, "Informatique", "Programmation et technologies",       95000),
        (6, "Art",          "Beaux-arts, musique et cinema",       60000),
        (7, "Economie",     "Finance, business et management",     75000),
        (8, "Enfants",      "Livres pour enfants et jeunesse",    300000),
    ]

    cursor.executemany(
        "INSERT OR IGNORE INTO categories VALUES (?, ?, ?, ?)",
        categories
    )

    conn.commit()
    conn.close()
    print("Base SQLite créée avec succès !")


def lire_categories():
    """Lit les données depuis SQLite"""
    conn = sqlite3.connect(DB_PATH)
    df = pd.read_sql("SELECT * FROM categories", conn)
    conn.close()
    print(f"Catégories lues : {len(df)}")
    print(df)
    return df


def upload_vers_minio(df):
    """Envoie les données vers MinIO bucket bronze"""
    client = boto3.client(
        "s3",
        endpoint_url="http://localhost:9000",
        aws_access_key_id="minioadmin",
        aws_secret_access_key="minioadmin"
    )

    today = datetime.now().strftime("%Y-%m-%d")
    fichier_minio = f"sql/categories_{today}.json"

    contenu = df.to_json(orient="records", force_ascii=False)

    client.put_object(
        Bucket="bronze",
        Key=fichier_minio,
        Body=contenu.encode("utf-8"),
        ContentType="application/json"
    )
    print(f"Uploaded : {fichier_minio}")


# ── Point d'entrée ──
if __name__ == "__main__":
    creer_base()
    df = lire_categories()
    upload_vers_minio(df)
    print("Terminé !")