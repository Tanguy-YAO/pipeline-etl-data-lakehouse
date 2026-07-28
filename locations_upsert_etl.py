# locations_upsert_etl.py (hardened + dynamic mapping + latitude/longitude)
import os, json, time, logging, unicodedata, re
from datetime import datetime, timezone

import gspread
import pandas as pd
import psycopg2
from psycopg2.extras import execute_values
from dotenv import load_dotenv
from google.oauth2.service_account import Credentials

# Logging & constantes

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger("locations_upsert_etl")

BATCH_SIZE = 1000
MAX_RETRIES = 3

# Helpers — nettoyage

_EMPTY = {"", "nan", "none", "null"}

def _is_empty(v) -> bool:
    return (v is None) or (pd.isna(v)) or (str(v).strip().lower() in _EMPTY)

def clean_value(v, *, to_title=False):
    if _is_empty(v):
        return None
    s = str(v).strip()
    if to_title:
        s = " ".join([w.capitalize() if (w.isupper() or w.islower()) else w for w in s.split()])
    return s

def clean_int(v):
    if _is_empty(v):
        return None
    s = str(v)
    s = (s.replace(",", "")
           .replace(" ", "")
           .replace("\xa0", "")
           .replace("\u202f", "")
           .replace(".", ""))
    try:
        return int(s)
    except Exception:
        try:
            return int(float(s))
        except Exception:
            return None

def clean_float(v):
    """Nettoyage pour LATITUDE / LONGITUDE (décimales, style 6.8234 ou 6,8234)"""
    if _is_empty(v):
        return None
    s = str(v).strip()
    s = (s.replace(" ", "")
           .replace("\xa0", "")
           .replace("\u202f", ""))
    s = s.replace(",", ".")
    try:
        return float(s)
    except Exception:
        return None

def strip_role_prefix(v, role_prefixes=("RSS", "DSM")):
    """
    "RSS / Barry amadou amadou" -> "Barry Amadou Amadou"
    Gère variantes: "RSS/", "RSS  /", "RSS -", "RSS:", "RSS   "
    """
    if _is_empty(v):
        return None
    s = str(v).strip()
    s0 = s
    for rp in role_prefixes:
        s = re.sub(rf"^\s*{rp}\s*[/:\-]?\s*", "", s, flags=re.IGNORECASE)
        if s != s0:
            break
    s = " ".join(w.capitalize() for w in s.split())
    return s or None

# Normalisation d'entêtes

def normalize_header(h: str) -> str:
    if h is None:
        return ""
    s = unicodedata.normalize("NFKD", str(h))
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"[^A-Za-z0-9]+", "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s.upper()

# Google Sheets

def _gs_client():
    load_dotenv()
    key_path = os.getenv("GOOGLE_APPLICATION_CREDENTIALS")
    assert key_path and os.path.exists(key_path), f"Clé JSON introuvable: {key_path}"
    scopes = ["https://www.googleapis.com/auth/spreadsheets.readonly"]
    creds = Credentials.from_service_account_file(key_path, scopes=scopes)
    client = gspread.authorize(creds)
    try:
        with open(key_path, "r", encoding="utf-8") as f:
            svc = json.load(f)
            logger.info(f"Service Account: {svc.get('client_email')}")
    except Exception:
        pass
    return client

def load_gsheet_df_by_env(env_id_key: str, env_ws_key: str, default_ws="Sheet1") -> pd.DataFrame:
    load_dotenv()
    spreadsheet_id = os.getenv(env_id_key)
    assert spreadsheet_id, f"Variable d'env manquante: {env_id_key}"
    ws_name = os.getenv(env_ws_key) or default_ws
    client = _gs_client()

    ss = client.open_by_key(spreadsheet_id)
    available = [ws.title for ws in ss.worksheets()]
    if ws_name not in available:
        raise RuntimeError(f"L'onglet '{ws_name}' est introuvable. Onglets disponibles: {available}")
    logger.info(f"Lecture de l'onglet '{ws_name}' du spreadsheet '{spreadsheet_id}'")

    tries = 0
    while True:
        try:
            sheet = ss.worksheet(ws_name)
            values = sheet.get_all_values(value_render_option='UNFORMATTED_VALUE',
                                          date_time_render_option='FORMATTED_STRING')
            break
        except Exception as e:
            tries += 1
            if tries >= 3:
                raise
            logger.warning(f"Echec lecture Sheets (try {tries}/3): {e}. Retry 1s…")
            time.sleep(1)

    if not values:
        raise RuntimeError(f"Le sheet {env_id_key}/{ws_name} est vide")

    headers, rows = values[0], values[1:]
    logger.info(f"Lignes brutes lues (hors header): {len(rows)}")

    norm_headers = [normalize_header(c) for c in headers]

    # Hack spécial : 2e "DECOUPAGE REGIONAL TEVIA" = RSS
    if norm_headers.count("DECOUPAGE_REGIONAL_TEVIA") >= 2 and "RSS" not in norm_headers:
        seen = 0
        for i, h in enumerate(norm_headers):
            if h == "DECOUPAGE_REGIONAL_TEVIA":
                seen += 1
                if seen == 2:
                    norm_headers[i] = "RSS"
                    logger.info(
                        "Header corrigé: 2e 'DECOUPAGE REGIONAL TEVIA' renommé en 'RSS' d'après le contenu."
                    )
                    break

    df = pd.DataFrame(rows, columns=norm_headers)
    return df

# ===============================================================
# DB — schéma & colonnes
# ===============================================================

def ensure_table_and_indexes(conn):
    with conn.cursor() as cur:
        cur.execute("""
        CREATE TABLE IF NOT EXISTS public.upya_locations (
            id                          SERIAL PRIMARY KEY,
            district                    VARCHAR(100),
            region                      VARCHAR(100),
            departement                 VARCHAR(100),
            sous_prefecture             VARCHAR(150),
            nombre_menages              INTEGER,
            decoupage_regional_tevia    VARCHAR(255),
            rss                         VARCHAR(255),
            dsm                         VARCHAR(255),
            regional_service_supervisor VARCHAR(255),
            latitude                    DOUBLE PRECISION,
            longitude                   DOUBLE PRECISION,
            last_update                 TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at                  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        """)

        # Migration : colonnes optionnelles au cas où la table existait déjà sans elles
        for col_def in [
            "ADD COLUMN IF NOT EXISTS latitude DOUBLE PRECISION",
            "ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION",
            "ADD COLUMN IF NOT EXISTS regional_service_supervisor VARCHAR(255)",
        ]:
            cur.execute(f"ALTER TABLE public.upya_locations {col_def};")

        # Contrainte UNIQUE pour l'upsert logique sur la "clé géographique"
        cur.execute("""
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.table_constraints
                WHERE table_schema='public' AND table_name='upya_locations'
                  AND constraint_type='UNIQUE' AND constraint_name='uk_location_key'
            ) THEN
                ALTER TABLE public.upya_locations
                ADD CONSTRAINT uk_location_key
                UNIQUE (district, region, departement, sous_prefecture);
            END IF;
        END$$;
        """)

        for q in [
            "CREATE INDEX IF NOT EXISTS idx_loc_region ON public.upya_locations(region)",
            "CREATE INDEX IF NOT EXISTS idx_loc_district ON public.upya_locations(district)",
            "CREATE INDEX IF NOT EXISTS idx_loc_departement ON public.upya_locations(departement)",
            "CREATE INDEX IF NOT EXISTS idx_loc_souspref ON public.upya_locations(sous_prefecture)",
        ]:
            cur.execute(q)

    conn.commit()
    logger.info("Schéma + contrainte UNIQUE + index OK")

# ===============================================================
# UPSERT
# ===============================================================

INSERT_COLS = [
    "district", "region", "departement", "sous_prefecture",
    "nombre_menages", "decoupage_regional_tevia", "rss", "dsm",
    "regional_service_supervisor",
    "latitude", "longitude",
    "last_update", "updated_at",
]

UPSERT_UPDATE_SET = """
nombre_menages              = EXCLUDED.nombre_menages,
decoupage_regional_tevia    = EXCLUDED.decoupage_regional_tevia,
rss                         = EXCLUDED.rss,
dsm                         = EXCLUDED.dsm,
regional_service_supervisor = EXCLUDED.regional_service_supervisor,
latitude                    = EXCLUDED.latitude,
longitude                   = EXCLUDED.longitude,
updated_at                  = EXCLUDED.updated_at,
last_update                 = EXCLUDED.last_update
"""

UPSERT_UPDATE_WHERE_DIFF = """
WHERE
  upya_locations.nombre_menages              IS DISTINCT FROM EXCLUDED.nombre_menages OR
  upya_locations.decoupage_regional_tevia    IS DISTINCT FROM EXCLUDED.decoupage_regional_tevia OR
  upya_locations.rss                         IS DISTINCT FROM EXCLUDED.rss OR
  upya_locations.dsm                         IS DISTINCT FROM EXCLUDED.dsm OR
  upya_locations.regional_service_supervisor IS DISTINCT FROM EXCLUDED.regional_service_supervisor OR
  upya_locations.latitude                    IS DISTINCT FROM EXCLUDED.latitude OR
  upya_locations.longitude                   IS DISTINCT FROM EXCLUDED.longitude
"""

def rows_from_df(df: pd.DataFrame, now_utc: datetime):
    for _, r in df.iterrows():
        yield (
            clean_value(r.get("district"),    to_title=True),
            clean_value(r.get("region"),      to_title=True),
            clean_value(r.get("departement"), to_title=True),
            clean_value(r.get("sous_prefecture"), to_title=True),
            clean_int(r.get("nombre_menages")),
            clean_value(r.get("decoupage_regional_tevia")),
            strip_role_prefix(r.get("rss")),
            strip_role_prefix(r.get("dsm")),
            clean_value(r.get("regional_service_supervisor"), to_title=True),
            clean_float(r.get("latitude")),
            clean_float(r.get("longitude")),
            now_utc,
            now_utc,
        )

def upsert_locations_batch(conn, df_batch: pd.DataFrame):
    if df_batch.empty:
        return 0
    now_utc   = datetime.now(timezone.utc)
    cols_sql  = ", ".join(INSERT_COLS)
    template  = "(" + ", ".join(["%s"] * len(INSERT_COLS)) + ")"
    insert_sql = f"""
    INSERT INTO public.upya_locations ({cols_sql})
    VALUES %s
    ON CONFLICT (district, region, departement, sous_prefecture) DO UPDATE SET
    {UPSERT_UPDATE_SET}
    {UPSERT_UPDATE_WHERE_DIFF}
    """
    data_iter = list(rows_from_df(df_batch, now_utc))
    with conn.cursor() as cur:
        execute_values(cur, insert_sql, data_iter, template=template, page_size=500)
    conn.commit()
    return len(data_iter)

# ===============================================================
# Dédup + Diff preview
# ===============================================================

def dedupe_geo(df: pd.DataFrame) -> pd.DataFrame:
    key_cols = ["district", "region", "departement", "sous_prefecture"]
    for c in key_cols:
        if c in df.columns:
            df[c] = df[c].astype(str).str.strip()
    return df.drop_duplicates(subset=key_cols, keep="last")

def compute_row_fingerprint(r):
    return json.dumps({
        "nombre_menages":              clean_int(r.get("nombre_menages")),
        "decoupage_regional_tevia":    clean_value(r.get("decoupage_regional_tevia")),
        "rss":                         strip_role_prefix(r.get("rss")),
        "dsm":                         strip_role_prefix(r.get("dsm")),
        "regional_service_supervisor": clean_value(r.get("regional_service_supervisor")),
        "latitude":                    clean_float(r.get("latitude")),
        "longitude":                   clean_float(r.get("longitude")),
    }, sort_keys=True, ensure_ascii=False)

def preview_delta(conn, df_clean: pd.DataFrame):
    with conn.cursor() as cur:
        cur.execute("""
          SELECT district, region, departement, sous_prefecture,
                 nombre_menages, decoupage_regional_tevia, rss, dsm,
                 regional_service_supervisor,
                 latitude, longitude
          FROM public.upya_locations
        """)
        rows = cur.fetchall()

    cols = [
        "district", "region", "departement", "sous_prefecture",
        "nombre_menages", "decoupage_regional_tevia", "rss", "dsm",
        "regional_service_supervisor",
        "latitude", "longitude",
    ]
    existing = pd.DataFrame(rows, columns=cols) if rows else pd.DataFrame(columns=cols)

    if existing.empty:
        logger.info(f"Δ preview — nouveaux: {len(df_clean)}, modifiés: 0, identiques: 0")
        return

    existing["_fingerprint"] = existing.apply(compute_row_fingerprint, axis=1)
    df_tmp = df_clean.copy()
    df_tmp["_fingerprint"] = df_tmp.apply(compute_row_fingerprint, axis=1)

    key = ["district", "region", "departement", "sous_prefecture"]
    merged = df_tmp.merge(
        existing[key + ["_fingerprint"]],
        on=key,
        how="left",
        suffixes=("", "_old"),
    )
    new_rows  = merged["_fingerprint_old"].isna().sum()
    unchanged = (merged["_fingerprint"] == merged["_fingerprint_old"]).sum()
    changed   = len(merged) - new_rows - unchanged
    logger.info(f"Δ preview — nouveaux: {new_rows}, modifiés: {changed}, identiques: {unchanged}")

# ===============================================================
# Main
# ===============================================================

def main():
    logger.info("DÉMARRAGE ETL upya_locations (Sheets → Postgres)")

    # 1) Extract Google Sheets
    df_raw = load_gsheet_df_by_env("GS_LOCATIONS_ID", "GS_LOCATIONS_WS", default_ws="Sheet1")

    # 2) Mapping colonnes dynamique
    nombre_key = None
    if "NOMBRE_MENAGES" in df_raw.columns:
        nombre_key = "NOMBRE_MENAGES"
    elif "NOMBRE_MENAG" in df_raw.columns:
        nombre_key = "NOMBRE_MENAG"
    else:
        raise RuntimeError(
            "Colonne 'NOMBRE MENAGES' introuvable (ni NOMBRE_MENAGES ni NOMBRE_MENAG) "
            f"dans les headers normalisés: {list(df_raw.columns)}"
        )

    lat_key = "LATITUDE"  if "LATITUDE"  in df_raw.columns else None
    lon_key = "LONGITUDE" if "LONGITUDE" in df_raw.columns else None
    if not lat_key or not lon_key:
        logger.warning(
            "Colonnes LATITUDE/LONGITUDE non trouvées dans le Google Sheet. "
            "Elles seront remplies à NULL."
        )

    # Détection dynamique de la colonne Regional Service Supervisor
    # (supporte plusieurs variantes de nommage possibles dans le sheet source)
    rss_supervisor_key = None
    for candidate in (
        "REGIONAL_SERVICE_SUPERVISOR",
        "REGIONAL_SERVICE8SUPERVISOR",   # faute de frappe connue
        "REGIONAL_SERVICE_SUPERVISEUR",
        "RSS_SUPERVISOR",
    ):
        if candidate in df_raw.columns:
            rss_supervisor_key = candidate
            logger.info(f"Colonne Regional Service Supervisor détectée sous: '{candidate}'")
            break
    if not rss_supervisor_key:
        logger.warning(
            "Colonne 'Regional Service Supervisor' introuvable dans le sheet. "
            "Elle sera remplie à NULL."
        )

    column_mapping = {
        "DISTRICT":                 "district",
        "REGION":                   "region",
        "DEPARTEMENT":              "departement",
        "SOUS_PREFECTURE":          "sous_prefecture",
        nombre_key:                 "nombre_menages",
        "DECOUPAGE_REGIONAL_TEVIA": "decoupage_regional_tevia",
        "RSS":                      "rss",
        "DSM":                      "dsm",
    }
    if rss_supervisor_key:
        column_mapping[rss_supervisor_key] = "regional_service_supervisor"
    if lat_key:
        column_mapping[lat_key] = "latitude"
    if lon_key:
        column_mapping[lon_key] = "longitude"

    df = df_raw.rename(columns=column_mapping)

    # Colonnes obligatoires
    expected = [
        "district", "region", "departement", "sous_prefecture",
        "nombre_menages", "decoupage_regional_tevia", "rss", "dsm",
    ]
    # Colonnes optionnelles
    optional = ["regional_service_supervisor", "latitude", "longitude"]

    missing = [c for c in expected if c not in df.columns]
    if missing:
        raise RuntimeError(
            f"Colonnes attendues manquantes après mapping: {missing}. "
            f"Headers normalisés trouvés: {list(df_raw.columns)}"
        )

    # S'assure que toutes les colonnes optionnelles existent (NULL si absentes)
    for col in optional:
        if col not in df.columns:
            df[col] = None

    df = df[expected + optional].copy()

    # 3) Nettoyage & standardisation
    df["nombre_menages"] = df["nombre_menages"].apply(clean_int)
    df["latitude"]       = df["latitude"].apply(clean_float)
    df["longitude"]      = df["longitude"].apply(clean_float)
    df["rss"]            = df["rss"].apply(strip_role_prefix)
    df["dsm"]            = df["dsm"].apply(strip_role_prefix)
    df["regional_service_supervisor"] = df["regional_service_supervisor"].apply(
        lambda x: clean_value(x, to_title=True)
    )

    # Standardise la casse des clés géographiques + logs de filtre
    key_cols = ["district", "region", "departement", "sous_prefecture"]
    for col in key_cols:
        before = len(df)
        df[col] = df[col].apply(lambda x: clean_value(x, to_title=True))
        df = df[df[col].notna() & (df[col].astype(str).str.strip() != "")]
        removed = before - len(df)
        if removed:
            logger.info(f"Filtre '{col}': {removed} ligne(s) supprimée(s) (vide/invalide).")

    nb_before = len(df)

    # 4) Dédup
    df = dedupe_geo(df)
    nb_after = len(df)
    if nb_after < nb_before:
        logger.info(f"Dédup: {nb_before - nb_after} doublon(s) supprimé(s) sur la clé géo.")

    # 5) Connexion DB
    load_dotenv()
    DB_HOST     = os.getenv("DB_HOST")
    DB_PORT     = int(os.getenv("DB_PORT") or 5432)
    DB_NAME     = os.getenv("DB_NAME")
    DB_USER     = os.getenv("DB_USER")
    DB_PASSWORD = os.getenv("DB_PASSWORD")
    assert all([DB_HOST, DB_NAME, DB_USER, DB_PASSWORD]), "Variables d'environnement DB manquantes"

    sslmode = "disable" if DB_HOST in ("localhost", "127.0.0.1") else "require"
    conn = psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=DB_PASSWORD, sslmode=sslmode,
    )
    logger.info("Connexion PostgreSQL établie")

    # 6) Schéma & index
    ensure_table_and_indexes(conn)

    # 7) Diff preview (info)
    preview_delta(conn, df)

    # 8) UPSERT par batch
    total   = len(df)
    batches = (total + BATCH_SIZE - 1) // BATCH_SIZE
    total_upserted = 0

    for b in range(batches):
        i0 = b * BATCH_SIZE
        i1 = min(i0 + BATCH_SIZE, total)
        logger.info(f"Lot {b+1}/{batches} — lignes {i0+1}..{i1}")
        df_batch = df.iloc[i0:i1].copy()
        df_batch = dedupe_geo(df_batch)  # dédup de sécurité intra-lot

        tries = 0
        while tries < MAX_RETRIES:
            try:
                count = upsert_locations_batch(conn, df_batch)
                total_upserted += count
                break
            except Exception as e:
                tries += 1
                logger.error(f"Erreur UPSERT lot (try {tries}/{MAX_RETRIES}): {e}")
                conn.rollback()
                if tries < MAX_RETRIES:
                    logger.info("⏳ Retry dans 5s…")
                    time.sleep(5)
                else:
                    logger.error("💥 Échec définitif du lot")
                    raise
        if b < batches - 1:
            time.sleep(0.3)

    conn.close()
    logger.info("=" * 60)
    logger.info("ETL upya_locations TERMINÉ")
    logger.info(f"• Lignes source (après filtres clé) : {nb_after}")
    logger.info(f"• UPSERT effectués                  : {total_upserted}")
    logger.info("=" * 60)


if __name__ == "__main__":
    main()