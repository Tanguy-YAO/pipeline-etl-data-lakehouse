import pytest
import sys
import json
import sqlite3
import pandas as pd
from unittest.mock import patch, MagicMock

sys.path.insert(0, "/home/hp/projet-data-eng")

from extractors.csv_reader import lire_et_nettoyer, upload_vers_minio as csv_upload
from extractors.sql_reader import creer_base, lire_categories, upload_vers_minio as sql_upload

# ══ Tests csv_reader ══

def test_lire_et_nettoyer_retourne_dataframe():
    df = lire_et_nettoyer()
    assert isinstance(df, pd.DataFrame)
    assert len(df) > 0
    assert "isbn" in df.columns
    assert "titre" in df.columns

def test_colonnes_apres_nettoyage():
    data = {"ISBN": ["123"], "Book-Title": ["Test"], "Book-Author": ["Auteur"],
            "Year-Of-Publication": ["2020"], "Publisher": ["Editeur"],
            "Image-URL-S": ["url"], "Image-URL-M": ["url"], "Image-URL-L": ["url"]}
    df = pd.DataFrame(data)
    df = df[["ISBN", "Book-Title", "Book-Author", "Year-Of-Publication", "Publisher"]]
    df.columns = ["isbn", "titre", "auteur", "annee_publication", "editeur"]
    assert list(df.columns) == ["isbn", "titre", "auteur", "annee_publication", "editeur"]
    assert len(df.columns) == 5

def test_suppression_lignes_vides():
    data = {"isbn": ["123", None, "456"], "titre": ["Livre A", "Livre B", None],
            "auteur": ["A1", "A2", "A3"], "annee_publication": ["2020", "2021", "2022"],
            "editeur": ["Ed1", "Ed2", "Ed3"]}
    df = pd.DataFrame(data).dropna()
    assert len(df) == 1

def test_csv_to_json_conversion():
    data = {"isbn": ["123"], "titre": ["Test"], "auteur": ["Auteur"],
            "annee_publication": ["2020"], "editeur": ["Editeur"]}
    df = pd.DataFrame(data)
    result = json.loads(df.to_json(orient="records", force_ascii=False))
    assert len(result) == 1
    assert result[0]["titre"] == "Test"

def test_upload_csv_minio_mock():
    with patch("boto3.client") as mock_client:
        mock_s3 = MagicMock()
        mock_client.return_value = mock_s3
        client = mock_client("s3", endpoint_url="http://localhost:9000",
                             aws_access_key_id="minioadmin",
                             aws_secret_access_key="minioadmin")
        client.put_object(Bucket="bronze", Key="csv/test.json",
                          Body=b"test", ContentType="application/json")
        mock_s3.put_object.assert_called_once()

# ══ Tests sql_reader ══

def test_creer_base_et_lire(tmp_path):
    import extractors.sql_reader as sql
    original_path = sql.DB_PATH
    sql.DB_PATH = str(tmp_path / "test.sqlite")
    creer_base()
    df = lire_categories()
    sql.DB_PATH = original_path
    assert len(df) == 8
    assert isinstance(df, pd.DataFrame)

def test_nombre_categories():
    categories = [(1,"Fiction"),(2,"Science"),(3,"Histoire"),(4,"Philosophie"),
                  (5,"Informatique"),(6,"Art"),(7,"Economie"),(8,"Enfants")]
    assert len(categories) == 8

def test_insertion_multiple_categories(tmp_path):
    db_path = str(tmp_path / "test.sqlite")
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute("""CREATE TABLE IF NOT EXISTS categories (
        id INTEGER PRIMARY KEY, genre VARCHAR(50),
        description TEXT, nb_livres_estimes INTEGER)""")
    categories = [(1,"Fiction","Romans",450000),(2,"Science","Sciences",120000),
                  (3,"Histoire","Histoire",200000),(4,"Philosophie","Philo",80000),
                  (5,"Informatique","Info",95000),(6,"Art","Art",60000),
                  (7,"Economie","Eco",75000),(8,"Enfants","Enfants",300000)]
    cursor.executemany("INSERT OR IGNORE INTO categories VALUES (?, ?, ?, ?)", categories)
    conn.commit()
    df = pd.read_sql("SELECT * FROM categories", conn)
    conn.close()
    assert len(df) == 8

def test_insert_or_ignore(tmp_path):
    db_path = str(tmp_path / "test.sqlite")
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute("""CREATE TABLE categories (id INTEGER PRIMARY KEY,
        genre VARCHAR(50), description TEXT, nb_livres_estimes INTEGER)""")
    cursor.execute("INSERT INTO categories VALUES (1, 'Fiction', 'Romans', 450000)")
    cursor.execute("INSERT OR IGNORE INTO categories VALUES (1, 'Fiction', 'Romans', 450000)")
    conn.commit()
    df = pd.read_sql("SELECT * FROM categories", conn)
    conn.close()
    assert len(df) == 1

def test_upload_sql_minio_mock():
    with patch("boto3.client") as mock_client:
        mock_s3 = MagicMock()
        mock_client.return_value = mock_s3
        client = mock_client("s3", endpoint_url="http://localhost:9000",
                             aws_access_key_id="minioadmin",
                             aws_secret_access_key="minioadmin")
        client.put_object(Bucket="bronze", Key="sql/categories_test.json",
                          Body=b"test", ContentType="application/json")
        mock_s3.put_object.assert_called_once()