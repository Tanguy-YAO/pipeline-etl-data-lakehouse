from pyspark.sql import SparkSession
from pyspark.sql.functions import col, regexp_replace, trim, when
import pandas as pd

# Création de la session Spark
spark = SparkSession.builder.appName("Transform Bronze to Silver").master("local[*]").getOrCreate()
spark.sparkContext.setLogLevel("ERROR")
print("Session Spark démarrée !")

# ── Lecture des données Bronze ──
pdf = pd.read_json("/home/hp/projet-data-eng/bronze_local/books.json")
df = spark.createDataFrame(pdf)
print(f"Lignes lues depuis Bronze : {df.count()}")
df.show(5)

# ── Transformations ──

# 1. Nettoyer le prix : supprimer "£" et convertir en décimal
df = df.withColumn("prix_clean", 
    regexp_replace(col("prix"), "[^0-9.]", "").cast("float"))

# 2. Convertir la note texte en nombre
df = df.withColumn("note_num",
    when(col("note") == "One",   1)
    .when(col("note") == "Two",   2)
    .when(col("note") == "Three", 3)
    .when(col("note") == "Four",  4)
    .when(col("note") == "Five",  5)
    .otherwise(0))

# 3. Nettoyer la disponibilité
df = df.withColumn("disponibilite", trim(col("disponibilite")))

# 4. Garder uniquement les colonnes utiles
df_silver = df.select("titre", "prix_clean", "note_num", "disponibilite")

print("Apres transformation :")
df_silver.show(5)

# ── Sauvegarde en JSON dans Silver ──
df_silver.coalesce(1).write.mode("overwrite").json(
    "file:///home/hp/projet-data-eng/silver_local/books"
)
print("Données sauvegardées dans Silver !")

# ── Upload Silver vers MinIO ──
import boto3
import os

def upload_silver_vers_minio():
    client = boto3.client(
        "s3",
        endpoint_url="http://localhost:9000",
        aws_access_key_id="minioadmin",
        aws_secret_access_key="minioadmin"
    )

    # Cherche le fichier JSON généré par Spark
    dossier = "/home/hp/projet-data-eng/silver_local/books"
    for fichier in os.listdir(dossier):
        if fichier.endswith(".json"):
            chemin_local = os.path.join(dossier, fichier)
            client.upload_file(
                chemin_local,
                "silver",
                f"books/books_clean_2026-02-22.json"
            )
            print(f"Uploaded vers MinIO silver : books/books_clean_2026-02-22.json")
            break

upload_silver_vers_minio()
print("Pipeline Bronze -> Silver terminé !")