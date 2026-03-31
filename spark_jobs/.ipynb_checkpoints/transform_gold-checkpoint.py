from pyspark.sql import SparkSession
from pyspark.sql.functions import avg, count, min, max, round
import pandas as pd
import boto3
import os

# Session Spark
spark = SparkSession.builder.appName("Transform Silver to Gold").master("local[*]").getOrCreate()
spark.sparkContext.setLogLevel("ERROR")
print("Session Spark démarrée !")

# Trouver automatiquement le fichier JSON dans le dossier Silver
dossier_silver = "/home/hp/projet-data-eng/silver_local/books/"
fichier_silver = [f for f in os.listdir(dossier_silver) if f.endswith(".json")][0]
chemin_silver = os.path.join(dossier_silver, fichier_silver)

print(f"Fichier Silver trouvé : {fichier_silver}")

pdf = pd.read_json(chemin_silver, lines = True)
df = spark.createDataFrame(pdf)
print(f"Lignes lues depuis Silver : {df.count()}")
df.show(5)

# Passons aux agrégations Gold

# Prix moyen, min, max et nombre de livres par note
df_gold = df.groupBy("note_num") \
    .agg(
        count("titre").alias("nb_livres"),
        round(avg("prix_clean"), 2).alias("prix_moyen"),
        min("prix_clean").alias("prix_min"),
        max("prix_clean").alias("prix_max"),
    ) \
    .orderBy("note_num")
print("Statistiques par note :")
df_gold.show()

# ── Sauvegarde locale Gold ──
df_gold.coalesce(1).write.mode("overwrite").json(
    "file:///home/hp/projet-data-eng/gold_local/stats_books"
)
print("Données Gold sauvegardées localement !")

# ── Upload vers MinIO Gold ──
dossier_gold = "/home/hp/projet-data-eng/gold_local/stats_books/"
fichier_gold = [f for f in os.listdir(dossier_gold) if f.endswith(".json")][0]
chemin_gold = os.path.join(dossier_gold, fichier_gold)

client = boto3.client(
    "s3",
    endpoint_url="http://localhost:9000",
    aws_access_key_id="minioadmin",
    aws_secret_access_key="minioadmin"
)
client.upload_file(chemin_gold, "gold", "stats/stats_books_2026-02-23.json")
print("Uploaded vers MinIO gold : stats/stats_books_2026-02-23.json")
print("Pipeline Silver -> Gold terminé !")