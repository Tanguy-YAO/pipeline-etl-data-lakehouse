import requests
from bs4 import BeautifulSoup
import json
import boto3
from datetime import datetime

def scraper_une_page(url):
    """Extrait les livres d'une seule page"""
    response = requests.get(url)
    soup = BeautifulSoup(response.text, "html.parser")
    
    livres = []
    for livre in soup.select("article.product_pod"):
        data = {
            "titre": livre.select_one("h3 a")["title"],
            "prix": livre.select_one(".price_color").text.strip(),
            "note": livre.select_one(".star-rating")["class"][1],
            "disponibilite": livre.select_one(".availability").text.strip()
        }
        livres.append(data)
    
    # Cherche le lien "next"
    next_btn = soup.select_one("li.next a")
    next_url = None
    if next_btn:
        base = "https://books.toscrape.com/catalogue/"
        next_url = base + next_btn["href"]
    
    return livres, next_url


def scraper_tous_les_livres(max_pages=5):
    """Parcourt plusieurs pages et collecte tous les livres"""
    url = "https://books.toscrape.com/catalogue/page-1.html"
    tous_les_livres = []
    page = 1

    while url and page <= max_pages:
        print(f"  Scraping page {page}...")
        livres, url = scraper_une_page(url)
        tous_les_livres.extend(livres)
        page += 1

    return tous_les_livres

def upload_vers_minio(livres):
    """Envoie les données JSON vers MinIO bucket bronze"""
    client = boto3.client(
        "s3",
        endpoint_url="http://localhost:9000",
        aws_access_key_id="minioadmin",
        aws_secret_access_key="minioadmin"
    )
    
    # Nom du fichier avec la date du jour
    today = datetime.now().strftime("%Y-%m-%d")
    fichier = f"books/raw_books_{today}.json"
    
    # Conversion en JSON
    contenu = json.dumps(livres, ensure_ascii=False, indent=2)
    
    # Upload
    client.put_object(
        Bucket="bronze",
        Key=fichier,
        Body=contenu.encode("utf-8"),
        ContentType="application/json"
    )
    print(f"Uploaded : {fichier}")

# ── Point d'entrée ──
if __name__ == "__main__":
    print("Démarrage du scraping...")
    livres = scraper_tous_les_livres(max_pages=3)
    print(f"Total : {len(livres)} livres extraits")
    upload_vers_minio(livres)
    print("Terminé !")