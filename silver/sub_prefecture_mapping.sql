-- silver/sub_prefecture_mapping.sql
--
-- Table de correspondance canonique pour les noms de sous-prefectures,
-- construite le 28/08/2026 suite a la decouverte de nombreux doublons
-- (variance de casse, prefixe "Sp ", accents manquants, fautes de frappe)
-- une fois le bug district/sub_prefecture corrige et la vraie diversite
-- des sous-prefectures exposee.
--
-- METHODE : detection par pg_trgm (similarite textuelle), CHAQUE fusion
-- validee manuellement (pas d'automatisation aveugle) pour eviter de
-- fusionner par erreur des lieux distincts qui se ressemblent
-- phonetiquement (ex: Bouandougou/Bougou, rejete volontairement).
--
-- MAINTENANCE : toute nouvelle sous-prefecture non couverte ici tombe
-- par defaut sur un simple INITCAP (voir requete d'utilisation) -- pas
-- d'echec, juste pas encore canonicalisee. A completer au fil de l'eau
-- si de nouveaux doublons apparaissent.

CREATE SCHEMA IF NOT EXISTS silver;

DROP TABLE IF EXISTS silver.sub_prefecture_mapping;

CREATE TABLE silver.sub_prefecture_mapping (
    raw_value_normalized  TEXT PRIMARY KEY,  -- cle de recherche : LOWER(REPLACE(sp_sans_prefixe, '-', ' '))
    canonical_value        TEXT NOT NULL,
    decision_source         TEXT NOT NULL,    -- 'fusion_validee' | 'distinct_valide'
    validated_at            DATE NOT NULL DEFAULT CURRENT_DATE,
    note                    TEXT
);

INSERT INTO silver.sub_prefecture_mapping (raw_value_normalized, canonical_value, decision_source, note) VALUES
    -- Fusions validees : meme lieu, variante d'accent/casse/separateur
    ('yakasse attobrou',      'Yakassé-Attobrou', 'fusion_validee', 'accent manquant'),
    ('yakassé attobrou',      'Yakassé-Attobrou', 'fusion_validee', 'separateur different'),
    ('ananguie',              'Ananguié',         'fusion_validee', 'accent manquant'),
    ('ananguié',              'Ananguié',         'fusion_validee', 'casse'),
    ('tiassale',              'Tiassalé',         'fusion_validee', 'accent manquant'),
    ('bouafle',               'Bouaflé',          'fusion_validee', 'accent manquant'),
    ('danane',                'Danané',           'fusion_validee', 'accent manquant'),
    ('adzope',                'Adzopé',           'fusion_validee', 'accent manquant'),
    ('zouan hounien',         'Zouan-Hounien',    'fusion_validee', 'variante casse'),
    ('zouhan hounien',        'Zouan-Hounien',    'fusion_validee', 'faute de frappe: zouhan->zouan'),
    ('ouaragahio',            'Ouragahio',        'fusion_validee', 'lettre en trop'),
    ('sanpedro',              'San-Pédro',        'fusion_validee', 'separateur et accent manquants'),
    ('san pedro',             'San-Pédro',        'fusion_validee', 'separateur et accent manquants'),
    ('aboisso comoe',         'Aboisso-Comoé',    'fusion_validee', 'separateur/accent'),
    ('aboisso comoé',         'Aboisso-Comoé',    'fusion_validee', 'separateur'),
    ('agnibilekro',           'Agnibilékrou',     'fusion_validee', 'orthographe officielle Agnibilékrou'),
    ('agnibilekrou',          'Agnibilékrou',     'fusion_validee', 'accent manquant'),
    ('attobrou',              'Yakassé-Attobrou', 'fusion_validee', 'troncature validee par Tanguy le 28/08/2026'),

    -- Distincts valides explicitement : NE PAS fusionner malgre la ressemblance
    ('biankouma',             'Biankouma',        'distinct_valide', 'distinct de Santa-Biankouma, valide 28/08/2026'),
    ('santa biankouma',       'Santa-Biankouma',  'distinct_valide', 'distinct de Biankouma, valide 28/08/2026'),
    ('duekoue',               'Duékoué',          'distinct_valide', 'distinct de Guezon-Duekoue, valide 28/08/2026'),
    ('guezon duekoue',        'Guezon-Duékoué',   'distinct_valide', 'distinct de Duekoue, valide 28/08/2026'),
    ('bouandougou',           'Bouandougou',      'distinct_valide', 'distinct de Bougou, valide 28/08/2026'),
    ('bougou',                'Bougou',           'distinct_valide', 'distinct de Bouandougou, valide 28/08/2026');