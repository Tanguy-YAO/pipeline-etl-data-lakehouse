import pandas as pd
import boto3
from datetime import datetime
import pytest
import sys
import json
import sqlite3
import pandas as pd
from unittest.mock import patch, MagicMock

sys.path.insert(0, "/home/hp/projet-data-eng")

# Imports des modules à tester
from extractors.csv_reader import lire_et_nettoyer, upload_vers_minio as csv_upload
from extractors.sql_reader import creer_base, lire_categories, upload_vers_minio as sql_upload

FICHIER = "/home/hp/projet-data-eng/config/books.csv"

def lire_et_nettoyer():
    """Lit et nettoie le CSV"""
    df = pd.read_csv(FICHIER, sep=";", encoding="latin-1", on_bad_lines="skip")
    colonnes_utiles = ["ISBN", "Book-Title", "Book-Author", "Year-Of-Publication", "Publisher"]
    df = df[colonnes_utiles]
    df.columns = ["isbn", "titre", "auteur", "annee_publication", "editeur"]
    df = df.dropna()
    print(f"Lignes après nettoyage : {len(df)}")
    return df

def upload_vers_minio(df):
    """Envoie le CSV vers MinIO bucket bronze"""
    client = boto3.client(
        "s3",
        endpoint_url="http://localhost:9000",
        aws_access_key_id="minioadmin",
        aws_secret_access_key="minioadmin"
    )
    today = datetime.now().strftime("%Y-%m-%d")
    fichier_minio = f"csv/books_kaggle_{today}.json"
    contenu = df.to_json(orient="records", force_ascii=False)
    client.put_object(
        Bucket="bronze", Key=fichier_minio,
        Body=contenu.encode("utf-8"), ContentType="application/json"
    )
    print(f"Uploaded : {fichier_minio} ({len(df)} lignes)")

# ── Point d'entrée ──
if __name__ == "__main__":
    df = lire_et_nettoyer()
    upload_vers_minio(df)
    print("Terminé !")

    