import pandas as pd
import boto3
import json
from datetime import datetime

# Chemin vers le fichier CSV
fichier = "/home/hp/projet-data-eng/config/books.csv"

# Lecture du CSV avec pandas
# sep=";" car les colonnes sont séparées par des points-virgules
df = pd.read_csv(fichier, sep=";", encoding="latin-1", on_bad_lines="skip")

# Exploration rapide
print(f"Nombre de lignes : {len(df)}")
print(f"Colonnes : {list(df.columns)}")
print(df.head(3))

# On garde seulement les colonnes utiles
colonnes_utiles = ["ISBN", "Book-Title", "Book-Author", "Year-Of-Publication", "Publisher"]
df = df[colonnes_utiles]

# On renomme pour avoir des noms propres
df.columns = ["isbn", "titre", "auteur", "annee_publication", "editeur"]

# On supprime les lignes avec des valeurs manquantes
df = df.dropna()

print(f"Lignes après nettoyage : {len(df)}")
print(df.head(3))

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

    # Conversion DataFrame → JSON
    contenu = df.to_json(orient="records", force_ascii=False)

    client.put_object(
        Bucket="bronze",
        Key=fichier_minio,
        Body=contenu.encode("utf-8"),
        ContentType="application/json"
    )
    print(f"Uploaded : {fichier_minio} ({len(df)} lignes)")


# ── Point d'entrée ──
if __name__ == "__main__":
    upload_vers_minio(df)
    print("Terminé !")