import pandas as pd
import os
from sqlalchemy import create_engine

# Trouver le fichier Gold
dossier = "/home/hp/projet-data-eng/gold_local/stats_books/"
fichier = [f for f in os.listdir(dossier) if f.endswith(".json")][0]
chemin = os.path.join(dossier, fichier)

# Lire les données Gold
df = pd.read_json(chemin, lines=True)
print("Données Gold chargées :")
print(df)

# Connexion PostgreSQL via SQLAlchemy
engine = create_engine("postgresql://airflow:airflow@localhost:5432/airflow")

# Insérer dans PostgreSQL
df.to_sql("gold_stats_books", engine, if_exists="replace", index=False)
print("Table gold_stats_books créée dans PostgreSQL !")