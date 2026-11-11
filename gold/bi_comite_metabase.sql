-- ============================================================================
-- bi-comite-metabase-v3.sql  (11/11/2026, v3.1)
-- v3.1 : avant le 01/11, les migrés présents dans UPYA (N…, T…) sont écartés,
--   comme dans les photos du comité (211 actifs upya_tevia en trop au 31/10).
-- Portefeuille consultable à n'importe quelle date, dans Metabase.
--
-- v3 : toutes les dates gardées, pour toujours, sans copier le portefeuille
--   chaque jour. La v2 stockait une copie complète par date (24 Mo par date,
--   8,7 Go par an) et ne gardait les jours ordinaires que 14 jours. La v3
--   n'enregistre que les changements : une ligne par contrat et par période
--   pendant laquelle son état n'a pas bougé (bi.contrat_etat), idem pour ses
--   conditions et ses acteurs (bi.contrat_attributs). Le retard de chaque date
--   se recalcule depuis la fin du crédit, qui ne change qu'au paiement.
--   Le passé reste figé : une date enregistrée ne se réécrit pas.
--   La credit manager choisit librement sa date ; le comité n'est plus qu'un
--   repère dans les libellés (jour paramétrable, table bi.jour_comite).
--
-- Objets
--   bi.attributs_contrat     attributs actuels (source des versions)
--   bi.contrat_etat          historique de l'état des contrats
--   bi.contrat_attributs     historique des conditions et des acteurs
--   bi.calendrier            une ligne par date enregistrée (libellé, repères)
--   bi.indicateurs_jour      agrégats par date (courbes d'évolution)
--   bi.collecte              paiements depuis 2025, recalculée chaque nuit
--   bi.jour_comite, bi.comites_ponctuels   repères de comité
--   Vues Metabase : bi.v_choix_photo, bi.v_portefeuille, bi.v_transitions,
--                   bi.v_evolution, bi.v_collecte ; bi.v_portefeuille_date
--                   (calcul, toutes dates)
--   Fonctions : bi.photographier_du_jour() (pipeline, chaque nuit),
--               bi.reconstruire() (repart de zéro, une fois),
--               bi.marquer_comite(date), bi.retirer_comite(date)
--
-- Règles (celles du comité) :
--   * Périmètre du comité : Comité TEVIA = upya_tevia + surge_tevia (surge_zeci
--     exclu depuis le 04/11) ; Comité GREENO = upya_greeno ; le reste « Hors
--     comité ».
--   * Contrats : PAYG, non annulés, activés. Actif = ENABLED ou LOCKED. Actifs
--     de toutes catégories ; soldés et repris pour TEVIA et GREENO (vintage).
--   * Retard : UPYA (y compris migrés après le 01/11) = date − fin du crédit ;
--     SURGE avant migration = jours bloqués consécutifs.
--   * PAR N = encours en retard de plus de N jours / encours actif (rapport de
--     sommes). PAR180 : 180 jours et plus.
--   * FPD (directrice, 22/10) : actif de plus de 30 jours ; net = total payé −
--     acompte ; net ≤ 0 FPD strict, 0 < net < mensualité FPD partiel. Les taux
--     présentés excluent les 120 jours et plus (comptés à part).
--   * Classe S1 : attendu = acompte + mensualité × max(⌊âge/30⌋ − 1, 0).
--   * Total payé à une date = valeur − reste à payer à cette date.
--
-- Exécution : tout le fichier d'un bloc dans pgAdmin, puis, à part, une fois :
--   SELECT * FROM bi.reconstruire();
-- Supprime les objets de la v2 (photos complètes), remplacés ici.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS bi;

-- Objets de la v2, remplacés par la v3
DROP VIEW IF EXISTS bi.v_collecte CASCADE;
DROP VIEW IF EXISTS bi.v_portefeuille CASCADE;
DROP VIEW IF EXISTS bi.v_transitions CASCADE;
DROP VIEW IF EXISTS bi.v_choix_photo CASCADE;
DROP FUNCTION IF EXISTS bi.rattrapage(date);
DROP FUNCTION IF EXISTS bi.calculer_transitions(date, date, text);
DROP FUNCTION IF EXISTS bi.photographier(date);
DROP FUNCTION IF EXISTS bi.marquer_comite(date, text);
DROP TABLE IF EXISTS bi.photo_transitions;
DROP TABLE IF EXISTS bi.photo_portefeuille;
DROP TABLE IF EXISTS bi.photos;


-- Référentiel des sources (déjà créé par bi-metabase-v1.sql ; repris ici sans
-- rien écraser pour que ce script se suffise à lui-même)
CREATE TABLE IF NOT EXISTS bi.ref_source_crm (
    source_crm  text PRIMARY KEY,
    entite      text NOT NULL,
    crm         text NOT NULL,
    libelle     text NOT NULL,
    ordre       int  NOT NULL
);
INSERT INTO bi.ref_source_crm VALUES
    ('upya_tevia',   'TEVIA',  'UPYA',  'TEVIA · UPYA',         1),
    ('surge_tevia',  'TEVIA',  'SURGE', 'TEVIA · SURGE',        2),
    ('surge_zeci',   'TEVIA',  'SURGE', 'TEVIA · SURGE ZECI',   3),
    ('upya_greeno',  'GREENO', 'UPYA',  'GREENO · UPYA',        4),
    ('surge_neotci', 'NEoTCI', 'SURGE', 'NEoTCI · SURGE',       5)
ON CONFLICT (source_crm) DO NOTHING;


-- Chaque photo lit gold.unified_daily_snapshot pour une seule date : un index
-- sur snapshot_date évite de parcourir tout l'historique (créé seulement si
-- c'est bien une table et s'il n'existe pas déjà).
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
               WHERE n.nspname = 'gold' AND c.relname = 'unified_daily_snapshot' AND c.relkind IN ('r', 'p'))
       AND NOT EXISTS (SELECT 1 FROM pg_index i
                       JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
                       WHERE i.indrelid = 'gold.unified_daily_snapshot'::regclass
                         AND a.attname = 'snapshot_date') THEN
        CREATE INDEX idx_unified_daily_snapshot_date ON gold.unified_daily_snapshot (snapshot_date);
    END IF;
END $$;
-- ----------------------------------------------------------------------------
-- 1. Attributs actuels des contrats (recalculés avant chaque photo)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bi.attributs_contrat (
    numero_contrat      text PRIMARY KEY,
    entite              text,
    categorie           text,
    crm                 text,
    produit             text,
    region              text,
    commercial          text,
    regional            text,
    dsm                 text,
    technicien          text,
    agent_recouvrement  text,
    nom_client          text,
    telephone           text,
    valeur_contrat      numeric,
    acompte             numeric,
    mensualite          numeric,
    maj_le              timestamptz DEFAULT now()
);

CREATE OR REPLACE FUNCTION bi.rafraichir_attributs()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
    TRUNCATE bi.attributs_contrat;

    INSERT INTO bi.attributs_contrat
    WITH tevia AS (
        SELECT numero_contrat, regional, dsm, technicien
        FROM credit.tevia_contrats
    ),
    greeno AS (
        SELECT DISTINCT ON (numero_contrat::text)
               numero_contrat::text AS numero_contrat,
               NULLIF(TRIM(agent_credit_greeno::text), '') AS agent
        FROM recouvrement.contrats
        WHERE categorie = 'upya_greeno'
        ORDER BY numero_contrat::text
    ),
    neotci AS (
        SELECT a.numero_contrat, g.nom_agent AS agent
        FROM recouvrement.attribution_neotci a
        JOIN recouvrement.agents_neotci g ON g.code_agent = a.code_agent
        WHERE a.mois = date_trunc('month', CURRENT_DATE)::date
    ),
    techniciens AS (
        SELECT DISTINCT ON (contract_number::text)
               contract_number::text AS numero_contrat,
               initcap(lower(NULLIF(TRIM(technician), ''))) AS technicien
        FROM gold.v_parcours_installation
        WHERE NULLIF(TRIM(technician), '') IS NOT NULL
        ORDER BY contract_number::text
    )
    SELECT
        c.contract_number::text,
        r.entite,
        c.categorie,
        r.crm,
        COALESCE(NULLIF(TRIM(c.product_name), ''), 'Non renseigné'),
        COALESCE(NULLIF(TRIM(c.region), ''), 'Non renseignée'),
        COALESCE(NULLIF(TRIM(c.agent_name), ''), 'Non renseigné'),
        COALESCE(t.regional, 'Non rattaché'),
        COALESCE(t.dsm, 'Non rattaché'),
        COALESCE(t.technicien, tk.technicien, 'Non renseigné'),
        COALESCE(n.agent, g.agent, 'Non attribué'),
        c.customer_name,
        c.phone_number,
        COALESCE(c.total_contract_value, 0),
        COALESCE(c.upfront_payment, 0),
        COALESCE(c.monthly_payment, 0),
        now()
    FROM gold.unified_contracts c
    JOIN bi.ref_source_crm r ON r.source_crm = c.categorie
    LEFT JOIN tevia t        ON t.numero_contrat  = c.contract_number::text
    LEFT JOIN greeno g       ON g.numero_contrat  = c.contract_number::text
    LEFT JOIN neotci n       ON n.numero_contrat  = c.contract_number::text
    LEFT JOIN techniciens tk ON tk.numero_contrat = c.contract_number::text
    WHERE c.deal_type = 'PAYG'
      AND c.contract_status <> 'CANCELLED'
    ON CONFLICT (numero_contrat) DO NOTHING;

    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

-- ----------------------------------------------------------------------------
-- 2. Jour du comité : un simple repère dans les libellés, paramétrable
--   bi.jour_comite       le jour de la semaine en vigueur depuis une date
--                        (1 = lundi … 7 = dimanche) ; jeudi depuis toujours.
--   bi.comites_ponctuels un comité déplacé une semaine donnée.
--   Toutes les dates sont gardées de toute façon : changer de jour ne fait
--   que changer les libellés à venir ; bi.marquer_comite() et
--   bi.retirer_comite() corrigent une date passée.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bi.jour_comite (
    depuis    date PRIMARY KEY,
    jour_iso  int  NOT NULL CHECK (jour_iso BETWEEN 1 AND 7)
);
INSERT INTO bi.jour_comite VALUES (DATE '2000-01-01', 4) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS bi.comites_ponctuels (
    date_comite  date PRIMARY KEY,
    action       text NOT NULL CHECK (action IN ('ajout', 'retrait')),
    motif        text
);

CREATE OR REPLACE FUNCTION bi.est_jour_comite(d date)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT action = 'ajout' FROM bi.comites_ponctuels WHERE date_comite = d),
        extract(isodow FROM d)::int = (SELECT jour_iso FROM bi.jour_comite
                                        WHERE depuis <= d ORDER BY depuis DESC LIMIT 1))
$$;

CREATE OR REPLACE FUNCTION bi.nom_jour(d date)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT (ARRAY['lundi','mardi','mercredi','jeudi','vendredi','samedi','dimanche'])[extract(isodow FROM d)::int]
$$;

CREATE OR REPLACE FUNCTION bi.libelle_photo(d date)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT to_char(d, 'YYYY-MM-DD') || ' · ' || bi.nom_jour(d)
        || CASE WHEN bi.est_jour_comite(d) THEN ' · comité' ELSE '' END
        || CASE WHEN d = (date_trunc('month', d) + interval '1 month - 1 day')::date
                THEN ' · fin de mois' ELSE '' END
$$;


-- ----------------------------------------------------------------------------
-- 3. Historique des contrats : une ligne par contrat et par période pendant
--    laquelle rien n'a changé (valide_du inclus, valide_au exclu, NULL = en
--    cours). L'état d'une date se lit en prenant la ligne valable ce jour-là.
--    Le retard n'est pas stocké : il se recalcule pour chaque date depuis la
--    fin du crédit (UPYA) ou le début du blocage (SURGE avant migration),
--    qui ne changent qu'au paiement ou au changement de statut.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bi.calendrier (
    date_photo    date PRIMARY KEY,
    est_comite    boolean NOT NULL,
    est_fin_mois  boolean NOT NULL,
    libelle       text    NOT NULL,
    nb_actifs     int,
    prise_le      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS bi.contrat_etat (
    numero_contrat   text NOT NULL,
    valide_du        date NOT NULL,
    valide_au        date,
    categorie        text,
    source           text,
    statut_kit       text,
    date_activation  date,
    fin_credit       date,
    debut_blocage    date,
    reste_a_payer    numeric,
    PRIMARY KEY (numero_contrat, valide_du)
);
CREATE INDEX IF NOT EXISTS idx_contrat_etat_periode
    ON bi.contrat_etat USING gist (daterange(valide_du, valide_au, '[)'));
CREATE INDEX IF NOT EXISTS idx_contrat_etat_ouvert
    ON bi.contrat_etat (numero_contrat) WHERE valide_au IS NULL;

CREATE TABLE IF NOT EXISTS bi.contrat_attributs (
    numero_contrat      text NOT NULL,
    valide_du           date NOT NULL,
    valide_au           date,
    entite              text,
    crm                 text,
    produit             text,
    region              text,
    commercial          text,
    regional            text,
    dsm                 text,
    technicien          text,
    agent_recouvrement  text,
    nom_client          text,
    telephone           text,
    valeur_contrat      numeric,
    acompte             numeric,
    mensualite          numeric,
    PRIMARY KEY (numero_contrat, valide_du)
);
CREATE INDEX IF NOT EXISTS idx_contrat_attributs_periode
    ON bi.contrat_attributs USING gist (daterange(valide_du, valide_au, '[)'));
CREATE INDEX IF NOT EXISTS idx_contrat_attributs_ouvert
    ON bi.contrat_attributs (numero_contrat) WHERE valide_au IS NULL;


-- ----------------------------------------------------------------------------
-- 4. Portefeuille à une date : la vue de calcul (règles du comité)
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS bi.v_portefeuille CASCADE;
DROP VIEW IF EXISTS bi.v_transitions CASCADE;
DROP VIEW IF EXISTS bi.v_choix_photo CASCADE;
DROP VIEW IF EXISTS bi.v_portefeuille_date CASCADE;
DROP VIEW IF EXISTS bi.v_transitions_date CASCADE;
DROP VIEW IF EXISTS bi.v_evolution CASCADE;

CREATE VIEW bi.v_portefeuille_date AS
SELECT
    c.date_photo,
    e.numero_contrat,
    COALESCE(a.entite, r.entite, 'Non classé')                     AS entite,
    e.categorie,
    COALESCE(a.crm, r.crm)                                         AS crm,
    CASE WHEN e.categorie IN ('upya_tevia', 'surge_tevia') THEN 'Comité TEVIA'
         WHEN e.categorie = 'upya_greeno'                  THEN 'Comité GREENO'
         ELSE 'Hors comité' END                                    AS perimetre,
    COALESCE(a.produit, 'Non renseigné')                           AS produit,
    COALESCE(a.region, 'Non renseignée')                           AS region,
    COALESCE(a.commercial, 'Non renseigné')                        AS commercial,
    COALESCE(a.regional, 'Non rattaché')                           AS regional,
    COALESCE(a.dsm, 'Non rattaché')                                AS dsm,
    COALESCE(a.technicien, 'Non renseigné')                        AS technicien,
    COALESCE(a.agent_recouvrement, 'Non attribué')                 AS agent_recouvrement,
    CASE WHEN e.date_activation < DATE '2026-01-01' THEN to_char(e.date_activation, 'YYYY')
         ELSE to_char(e.date_activation, 'YYYY-MM') END            AS cohorte,
    CASE WHEN e.date_activation < DATE '2026-01-01' THEN date_trunc('year', e.date_activation)::date
         ELSE date_trunc('month', e.date_activation)::date END     AS cohorte_debut,
    e.statut_kit,
    k.actif,
    e.date_activation,
    k.age                                                          AS age_jours,
    k.retard                                                       AS jours_retard,
    CASE WHEN k.actif THEN credit.tranche(k.retard) ELSE 'Hors portefeuille actif' END AS tranche_retard,
    k.valeur                                                       AS valeur_contrat,
    k.acpt                                                         AS acompte,
    k.mens                                                         AS mensualite,
    k.paye                                                         AS total_paye,
    k.reste                                                        AS reste_a_payer,
    -- mesures prêtes à additionner (0 hors périmètre)
    CASE WHEN k.actif THEN 1 ELSE 0 END                            AS nb_actifs,
    CASE WHEN k.actif THEN k.reste ELSE 0 END                      AS encours,
    CASE WHEN k.actif AND k.retard > 0   THEN k.reste ELSE 0 END   AS encours_par1,
    CASE WHEN k.actif AND k.retard > 30  THEN k.reste ELSE 0 END   AS encours_par30,
    CASE WHEN k.actif AND k.retard > 60  THEN k.reste ELSE 0 END   AS encours_par60,
    CASE WHEN k.actif AND k.retard > 90  THEN k.reste ELSE 0 END   AS encours_par90,
    CASE WHEN k.actif AND k.retard > 120 THEN k.reste ELSE 0 END   AS encours_par120,
    CASE WHEN k.actif AND k.retard >= 180 THEN k.reste ELSE 0 END  AS encours_par180,
    CASE WHEN k.actif AND k.retard IS NULL THEN 1 ELSE 0 END       AS nb_retard_inconnu,
    k.fpd                                                          AS statut_fpd,
    CASE WHEN k.fpd <> 'Non évaluable' THEN 1 ELSE 0 END           AS nb_fpd_evaluables,
    CASE WHEN k.fpd = 'FPD strict'  AND COALESCE(k.retard, 0) < 120 THEN 1 ELSE 0 END AS nb_fpd_strict,
    CASE WHEN k.fpd = 'FPD partiel' AND COALESCE(k.retard, 0) < 120 THEN 1 ELSE 0 END AS nb_fpd_partiel,
    CASE WHEN k.fpd IN ('FPD strict', 'FPD partiel') AND COALESCE(k.retard, 0) < 120 THEN 1 ELSE 0 END AS nb_fpd,
    CASE WHEN k.fpd IN ('FPD strict', 'FPD partiel') AND COALESCE(k.retard, 0) >= 120 THEN 1 ELSE 0 END AS nb_fpd_120_plus,
    CASE WHEN k.fpd IN ('FPD strict', 'FPD partiel') AND COALESCE(k.retard, 0) < 120 THEN k.reste ELSE 0 END AS encours_fpd,
    CASE WHEN NOT k.actif     THEN 'Hors portefeuille actif'
         WHEN k.paye > k.att  THEN '1. Advance'
         WHEN k.paye = k.att  THEN '2. Current'
         ELSE '3. Arriéré' END                                     AS classe_s1,
    CASE WHEN k.actif THEN k.att ELSE 0 END                        AS attendu_s1,
    CASE WHEN k.actif THEN GREATEST(k.att - k.paye, 0) ELSE 0 END  AS arriere_s1,
    CASE WHEN e.statut_kit = 'REPOSSESSED' THEN 0
         ELSE LEAST(k.valeur, k.acpt + k.mens / 30.0 * GREATEST(k.age - 30, 0)) END AS attendu_vintage,
    CASE WHEN e.statut_kit IN ('PAID_OFF', 'PAIDOFF') THEN 1 ELSE 0 END AS nb_soldes,
    CASE WHEN e.statut_kit = 'REPOSSESSED' THEN 1 ELSE 0 END       AS nb_repris,
    a.nom_client,
    a.telephone
FROM bi.calendrier c
JOIN bi.contrat_etat e
  ON daterange(e.valide_du, e.valide_au, '[)') @> c.date_photo
LEFT JOIN bi.contrat_attributs a
  ON a.numero_contrat = e.numero_contrat
 AND daterange(a.valide_du, a.valide_au, '[)') @> c.date_photo
LEFT JOIN bi.ref_source_crm r ON r.source_crm = e.categorie
CROSS JOIN LATERAL (
    SELECT b.*,
           CASE WHEN NOT b.actif OR b.age <= 30  THEN 'Non évaluable'
                WHEN b.paye - b.acpt <= 0        THEN 'FPD strict'
                WHEN b.paye - b.acpt < b.mens    THEN 'FPD partiel'
                ELSE 'Non FPD' END                                 AS fpd,
           b.acpt + b.mens * GREATEST(floor(b.age / 30.0) - 1, 0)  AS att
    FROM (
        SELECT e.statut_kit IN ('ENABLED', 'LOCKED')               AS actif,
               c.date_photo - e.date_activation                    AS age,
               CASE WHEN e.statut_kit NOT IN ('ENABLED', 'LOCKED') THEN NULL
                    WHEN e.source = 'surge'
                         THEN COALESCE(c.date_photo - e.debut_blocage, 0)
                    WHEN e.fin_credit IS NULL THEN NULL
                    ELSE GREATEST(c.date_photo - e.fin_credit, 0) END AS retard,
               COALESCE(a.valeur_contrat, 0)                       AS valeur,
               COALESCE(a.acompte, 0)                              AS acpt,
               COALESCE(a.mensualite, 0)                           AS mens,
               COALESCE(e.reste_a_payer, 0)                        AS reste,
               GREATEST(COALESCE(a.valeur_contrat, 0) - COALESCE(e.reste_a_payer, 0), 0) AS paye
    ) b
) k;


-- ----------------------------------------------------------------------------
-- 5. Indicateurs par jour (pour les courbes d'évolution, toutes dates d'un coup)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bi.indicateurs_jour (
    date_photo          date NOT NULL,
    perimetre           text,
    entite              text,
    categorie           text,
    regional            text,
    dsm                 text,
    commercial          text,
    agent_recouvrement  text,
    nb_actifs           bigint,
    encours             numeric,
    encours_par1        numeric,
    encours_par30       numeric,
    encours_par60       numeric,
    encours_par90       numeric,
    encours_par120      numeric,
    encours_par180      numeric,
    nb_fpd_evaluables   bigint,
    nb_fpd              bigint,
    encours_fpd         numeric
);
CREATE INDEX IF NOT EXISTS idx_indicateurs_jour_date ON bi.indicateurs_jour (date_photo);


-- ----------------------------------------------------------------------------
-- 6. Enregistrer une date
--    Les dates s'enregistrent dans l'ordre : une date déjà passée ne se
--    réécrit pas (le passé reste figé). bi.reconstruire() repart de zéro.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bi.photographier(d date)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_der    date := (SELECT MAX(date_photo) FROM bi.calendrier);
    v_actifs int;
    v_nouv   int;
BEGIN
    IF v_der IS NOT NULL AND d <= v_der THEN
        RETURN d || ' : déjà enregistrée (dernière date : ' || v_der || ')';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM gold.unified_daily_snapshot WHERE snapshot_date = d) THEN
        RETURN d || ' : pas de photo quotidienne dans gold.unified_daily_snapshot';
    END IF;

    -- État du jour, mêmes règles que les comités : PAYG, non annulé, activé ;
    -- actifs de toutes catégories, soldés et repris pour TEVIA et GREENO.
    -- Numéros SURGE renumérotés (T…, N…) ; avant le 01/11 la ligne SURGE fait
    -- foi, après la ligne UPYA.
    IF to_regclass('pg_temp._etat') IS NOT NULL THEN DROP TABLE pg_temp._etat; END IF;
    CREATE TEMP TABLE _etat AS
    SELECT DISTINCT ON (n.numero)
           n.numero                                  AS numero_contrat,
           s.categorie,
           s.source,
           s.contract_status                         AS statut_kit,
           s.registration_date::date                 AS date_activation,
           CASE WHEN s.source <> 'surge' THEN s.next_status_update::date END AS fin_credit,
           CASE WHEN s.source = 'surge' AND COALESCE(s.consecutive_locked_days, 0) > 0
                THEN d - s.consecutive_locked_days::int END AS debut_blocage,
           COALESCE(s.remaining_debt, 0)             AS reste_a_payer
    FROM gold.unified_daily_snapshot s
    CROSS JOIN LATERAL (
        SELECT CASE WHEN s.source = 'surge' AND s.contract_number::text ~ '^[0-9]+$'
                    THEN CASE WHEN s.categorie = 'surge_neotci' THEN 'N' ELSE 'T' END || s.contract_number::text
                    ELSE s.contract_number::text END AS numero
    ) n
    LEFT JOIN bi.ref_source_crm r ON r.source_crm = s.categorie
    WHERE s.snapshot_date = d
      AND s.deal_type = 'PAYG'
      AND s.contract_status <> 'CANCELLED'
      AND s.registration_date IS NOT NULL
      AND (s.contract_status IN ('ENABLED', 'LOCKED') OR r.entite IN ('TEVIA', 'GREENO'))
      -- avant la bascule du 01/11, les contrats migrés déjà chargés dans UPYA
      -- (numéros N…, T…) ne comptent pas : SURGE fait foi (211 actifs au 31/10,
      -- absents de la photo du comité)
      AND NOT (s.source = 'upya' AND s.contract_number::text ~ '^[NT][0-9]' AND d < DATE '2026-11-01')
    ORDER BY n.numero,
             (s.source = CASE WHEN d < DATE '2026-11-01' THEN 'surge' ELSE 'upya' END) DESC;

    -- Contrats dont l'état a changé ou qui ont quitté le périmètre : on clôt
    UPDATE bi.contrat_etat e SET valide_au = d
    WHERE e.valide_au IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM _etat t
          WHERE t.numero_contrat = e.numero_contrat
            AND t.categorie       IS NOT DISTINCT FROM e.categorie
            AND t.source          IS NOT DISTINCT FROM e.source
            AND t.statut_kit      IS NOT DISTINCT FROM e.statut_kit
            AND t.date_activation IS NOT DISTINCT FROM e.date_activation
            AND t.fin_credit      IS NOT DISTINCT FROM e.fin_credit
            AND t.debut_blocage   IS NOT DISTINCT FROM e.debut_blocage
            AND t.reste_a_payer   IS NOT DISTINCT FROM e.reste_a_payer);

    -- Nouveaux états
    INSERT INTO bi.contrat_etat (numero_contrat, valide_du, categorie, source, statut_kit,
                                 date_activation, fin_credit, debut_blocage, reste_a_payer)
    SELECT t.numero_contrat, d, t.categorie, t.source, t.statut_kit,
           t.date_activation, t.fin_credit, t.debut_blocage, t.reste_a_payer
    FROM _etat t
    WHERE NOT EXISTS (SELECT 1 FROM bi.contrat_etat e
                      WHERE e.numero_contrat = t.numero_contrat AND e.valide_au IS NULL);
    GET DIAGNOSTICS v_nouv = ROW_COUNT;

    -- Attributs (conditions, acteurs) : même principe, depuis bi.attributs_contrat
    UPDATE bi.contrat_attributs a SET valide_au = d
    WHERE a.valide_au IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM bi.attributs_contrat x
          WHERE x.numero_contrat = a.numero_contrat
            AND x.entite             IS NOT DISTINCT FROM a.entite
            AND x.crm                IS NOT DISTINCT FROM a.crm
            AND x.produit            IS NOT DISTINCT FROM a.produit
            AND x.region             IS NOT DISTINCT FROM a.region
            AND x.commercial         IS NOT DISTINCT FROM a.commercial
            AND x.regional           IS NOT DISTINCT FROM a.regional
            AND x.dsm                IS NOT DISTINCT FROM a.dsm
            AND x.technicien         IS NOT DISTINCT FROM a.technicien
            AND x.agent_recouvrement IS NOT DISTINCT FROM a.agent_recouvrement
            AND x.nom_client         IS NOT DISTINCT FROM a.nom_client
            AND x.telephone          IS NOT DISTINCT FROM a.telephone
            AND x.valeur_contrat     IS NOT DISTINCT FROM a.valeur_contrat
            AND x.acompte            IS NOT DISTINCT FROM a.acompte
            AND x.mensualite         IS NOT DISTINCT FROM a.mensualite);

    INSERT INTO bi.contrat_attributs (numero_contrat, valide_du, entite, crm, produit, region,
           commercial, regional, dsm, technicien, agent_recouvrement, nom_client, telephone,
           valeur_contrat, acompte, mensualite)
    SELECT x.numero_contrat,
           -- première date : les attributs valent depuis toujours (rattrapage)
           CASE WHEN v_der IS NULL THEN DATE '2000-01-01' ELSE d END,
           x.entite, x.crm, x.produit, x.region, x.commercial, x.regional, x.dsm,
           x.technicien, x.agent_recouvrement, x.nom_client, x.telephone,
           x.valeur_contrat, x.acompte, x.mensualite
    FROM bi.attributs_contrat x
    WHERE NOT EXISTS (SELECT 1 FROM bi.contrat_attributs a
                      WHERE a.numero_contrat = x.numero_contrat AND a.valide_au IS NULL);

    SELECT COUNT(*) FILTER (WHERE statut_kit IN ('ENABLED', 'LOCKED')) INTO v_actifs FROM _etat;

    INSERT INTO bi.calendrier (date_photo, est_comite, est_fin_mois, libelle, nb_actifs)
    VALUES (d, bi.est_jour_comite(d),
            d = (date_trunc('month', d) + interval '1 month - 1 day')::date,
            bi.libelle_photo(d), v_actifs);

    INSERT INTO bi.indicateurs_jour
    SELECT date_photo, perimetre, entite, categorie, regional, dsm, commercial, agent_recouvrement,
           SUM(nb_actifs), SUM(encours), SUM(encours_par1), SUM(encours_par30), SUM(encours_par60),
           SUM(encours_par90), SUM(encours_par120), SUM(encours_par180),
           SUM(nb_fpd_evaluables), SUM(nb_fpd), SUM(encours_fpd)
    FROM bi.v_portefeuille_date
    WHERE date_photo = d
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8;

    DROP TABLE pg_temp._etat;
    RETURN bi.libelle_photo(d) || ' : ' || v_actifs || ' actifs, ' || v_nouv || ' états nouveaux ou modifiés';
END;
$$;

-- Comité déplacé : corrige le repère d'une date déjà enregistrée
CREATE OR REPLACE FUNCTION bi.marquer_comite(d date, motif text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO bi.comites_ponctuels VALUES (d, 'ajout', motif)
    ON CONFLICT (date_comite) DO UPDATE SET action = 'ajout', motif = EXCLUDED.motif;
    UPDATE bi.calendrier SET est_comite = true, libelle = bi.libelle_photo(d) WHERE date_photo = d;
    RETURN bi.libelle_photo(d);
END;
$$;

CREATE OR REPLACE FUNCTION bi.retirer_comite(d date, motif text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO bi.comites_ponctuels VALUES (d, 'retrait', motif)
    ON CONFLICT (date_comite) DO UPDATE SET action = 'retrait', motif = EXCLUDED.motif;
    UPDATE bi.calendrier SET est_comite = false, libelle = bi.libelle_photo(d) WHERE date_photo = d;
    RETURN bi.libelle_photo(d);
END;
$$;

-- Appelée par le pipeline chaque nuit, après la photo quotidienne de gold
CREATE OR REPLACE FUNCTION bi.photographier_du_jour()
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    d   date := (SELECT MAX(snapshot_date) FROM gold.unified_daily_snapshot);
    res text := '';
    j   date;
BEGIN
    PERFORM bi.rafraichir_attributs();
    PERFORM bi.rafraichir_collecte();
    -- rattrape aussi les jours manqués (pipeline en échec), dans l'ordre
    FOR j IN SELECT DISTINCT snapshot_date FROM gold.unified_daily_snapshot
             WHERE snapshot_date > COALESCE((SELECT MAX(date_photo) FROM bi.calendrier), d - 1)
               AND snapshot_date <= d
             ORDER BY 1
    LOOP
        res := bi.photographier(j);
    END LOOP;
    RETURN COALESCE(NULLIF(res, ''), 'Rien de nouveau : ' || d || ' déjà enregistrée');
END;
$$;

-- Repart de zéro : toutes les dates de la photo quotidienne, dans l'ordre.
-- Les attributs (acteurs, conditions) sont ceux d'aujourd'hui pour tout le passé.
CREATE OR REPLACE FUNCTION bi.reconstruire()
RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE d date;
BEGIN
    TRUNCATE bi.calendrier, bi.contrat_etat, bi.contrat_attributs, bi.indicateurs_jour;
    PERFORM bi.rafraichir_attributs();
    PERFORM bi.rafraichir_collecte();
    FOR d IN SELECT DISTINCT snapshot_date FROM gold.unified_daily_snapshot ORDER BY 1 LOOP
        RETURN NEXT bi.photographier(d);
    END LOOP;
END;
$$;


-- ----------------------------------------------------------------------------
-- 7. Vues lues par Metabase
-- ----------------------------------------------------------------------------
-- Choix de la date. « Dernière photo » suit toujours la plus récente : valeur
-- par défaut du tableau de bord. Les autres libellés : « 2026-11-05 · jeudi ·
-- comité », « 2026-10-31 · samedi · fin de mois », « 2026-11-09 · lundi ».
CREATE VIEW bi.v_choix_photo AS
SELECT 'Dernière photo'::text AS photo, MAX(date_photo) AS date_photo, 0 AS ordre
FROM bi.calendrier
UNION ALL
SELECT libelle, date_photo, (ROW_NUMBER() OVER (ORDER BY date_photo DESC))::int
FROM bi.calendrier;

-- Le portefeuille d'une date choisie
CREATE VIEW bi.v_portefeuille AS
SELECT ch.photo, p.*
FROM bi.v_choix_photo ch
JOIN bi.v_portefeuille_date p ON p.date_photo = ch.date_photo;

-- Transitions d'une date choisie vers une date de comparaison :
--   « Semaine précédente » = la date enregistrée 7 à 10 jours avant ;
--   « Fin du mois précédent » = la dernière date du mois précédent.
CREATE VIEW bi.v_transitions AS
SELECT ch.photo, ch.date_photo, cmp.comparaison, cmp.date_depart, t.*
FROM bi.v_choix_photo ch
CROSS JOIN LATERAL (VALUES
    ('Semaine précédente',
     (SELECT MAX(date_photo) FROM bi.calendrier
       WHERE date_photo BETWEEN ch.date_photo - 10 AND ch.date_photo - 7)),
    ('Fin du mois précédent',
     (SELECT MAX(date_photo) FROM bi.calendrier
       WHERE date_photo < date_trunc('month', ch.date_photo)::date))
) cmp(comparaison, date_depart)
CROSS JOIN LATERAL (
    SELECT COALESCE(p1.numero_contrat, p0.numero_contrat)       AS numero_contrat,
           COALESCE(p1.entite, p0.entite)                       AS entite,
           COALESCE(p1.categorie, p0.categorie)                 AS categorie,
           COALESCE(p1.perimetre, p0.perimetre)                 AS perimetre,
           COALESCE(p1.regional, p0.regional)                   AS regional,
           COALESCE(p1.dsm, p0.dsm)                             AS dsm,
           COALESCE(p1.commercial, p0.commercial)               AS commercial,
           COALESCE(p1.agent_recouvrement, p0.agent_recouvrement) AS agent_recouvrement,
           COALESCE(p1.cohorte, p0.cohorte)                     AS cohorte,
           CASE WHEN p0.numero_contrat IS NULL THEN '3. Entrés'
                WHEN p1.numero_contrat IS NULL THEN '2. Sortis'
                ELSE '1. Présents aux deux dates' END           AS groupe,
           COALESCE(p0.tranche_retard, '0bis. Nouveau dans le portefeuille') AS tranche_depart,
           COALESCE(p1.tranche_retard, '8. Sorti du portefeuille')           AS tranche_arrivee,
           1                                                    AS nb_contrats,
           COALESCE(p0.encours, 0)                              AS encours_depart,
           COALESCE(p1.encours, 0)                              AS encours_arrivee,
           COALESCE(p0.encours_par30, 0)                        AS encours_par30_depart,
           COALESCE(p1.encours_par30, 0)                        AS encours_par30_arrivee
    FROM (SELECT * FROM bi.v_portefeuille_date WHERE date_photo = ch.date_photo AND actif) p1
    FULL JOIN (SELECT * FROM bi.v_portefeuille_date WHERE date_photo = cmp.date_depart AND actif) p0
           ON p0.numero_contrat = p1.numero_contrat
) t
WHERE cmp.date_depart IS NOT NULL;

-- Évolution : toutes les dates enregistrées, avec leur libellé et leurs repères
CREATE VIEW bi.v_evolution AS
SELECT c.libelle AS photo, c.est_comite, c.est_fin_mois, i.*
FROM bi.indicateurs_jour i
JOIN bi.calendrier c USING (date_photo);
-- ----------------------------------------------------------------------------
-- 4 bis. Collecte : paiements depuis 2025 (recharges et acomptes), un par ligne,
--        rattachés aux acteurs actuels du contrat. Recalculée chaque nuit.
--        Numéros SURGE ramenés au numéro migré (T…, N…) quand il existe.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bi.collecte (
    date_paiement       date,
    mois_paiement       date,
    numero_contrat      text,
    entite              text,
    categorie           text,
    perimetre           text,
    type_paiement       text,
    montant             numeric,
    commercial          text,
    regional            text,
    dsm                 text,
    agent_recouvrement  text
);
CREATE INDEX IF NOT EXISTS idx_collecte_date ON bi.collecte (date_paiement);

CREATE OR REPLACE FUNCTION bi.rafraichir_collecte()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
    TRUNCATE bi.collecte;
    INSERT INTO bi.collecte
    WITH migres AS MATERIALIZED (
        SELECT substring(contract_number FROM 2) AS numero_origine,
               contract_number::text            AS numero_contrat
        FROM silver.upya_contracts
        WHERE contract_number ~ '^[NT][0-9]+$'
    )
    SELECT
        t.payment_date::date,
        date_trunc('month', t.payment_date)::date,
        a.numero_contrat,
        a.entite,
        a.categorie,
        CASE WHEN a.categorie IN ('upya_tevia', 'surge_tevia') THEN 'Comité TEVIA'
             WHEN a.categorie = 'upya_greeno'                  THEN 'Comité GREENO'
             ELSE 'Hors comité' END,
        CASE t.normalized_reason WHEN 'recharge' THEN 'Recharge' ELSE 'Acompte' END,
        t.amount,
        a.commercial,
        a.regional,
        a.dsm,
        a.agent_recouvrement
    FROM gold.unified_transactions t
    LEFT JOIN migres m ON m.numero_origine = t.contract_number::text
    JOIN bi.attributs_contrat a ON a.numero_contrat = COALESCE(m.numero_contrat, t.contract_number::text)
    WHERE t.normalized_reason IN ('recharge', 'upfront_payment')
      AND COALESCE(t.ignore_payment, false) = false
      AND t.payment_date >= DATE '2025-01-01';
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;


CREATE VIEW bi.v_collecte AS
SELECT * FROM bi.collecte;


-- ----------------------------------------------------------------------------
-- 8. Droits de lecture (Metabase lit avec role_read)
-- ----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA bi TO role_read;
GRANT SELECT ON bi.calendrier, bi.contrat_etat, bi.contrat_attributs, bi.indicateurs_jour,
                bi.collecte, bi.attributs_contrat, bi.jour_comite, bi.comites_ponctuels,
                bi.v_choix_photo, bi.v_portefeuille_date, bi.v_portefeuille,
                bi.v_transitions, bi.v_evolution, bi.v_collecte TO role_read;


-- ----------------------------------------------------------------------------
-- 9. À lancer à part, une fois : reconstruction depuis la première photo
--    quotidienne de gold (une ligne de résultat par date ; plusieurs minutes)
-- ----------------------------------------------------------------------------
-- SELECT * FROM bi.reconstruire();
--
-- Pipeline, chaque nuit après « Gold - Snapshot quotidien unified_contracts » :
-- SELECT bi.photographier_du_jour();
--
-- Changer de jour de comité (exemple : le mardi à partir du 01/12/2026) :
-- INSERT INTO bi.jour_comite VALUES (DATE '2026-12-01', 2);
-- Comité déplacé une fois : SELECT bi.marquer_comite(DATE '2026-12-25', 'Noël');
--                           SELECT bi.retirer_comite(DATE '2026-12-24', 'Noël');
--
-- Contrôles :
-- SELECT date_photo, libelle, nb_actifs FROM bi.calendrier ORDER BY 1;
-- SELECT pg_size_pretty(pg_total_relation_size('bi.contrat_etat')) AS etat,
--        pg_size_pretty(pg_total_relation_size('bi.contrat_attributs')) AS attributs;
-- -- 31/10, à comparer aux comités de fin octobre (TEVIA 24,1 %, GREENO 16,9 %) :
-- SELECT perimetre, categorie, SUM(nb_actifs) AS actifs, ROUND(SUM(encours)) AS encours,
--        ROUND(100 * SUM(encours_par30) / NULLIF(SUM(encours), 0), 1) AS par30
-- FROM bi.v_portefeuille WHERE photo LIKE '2026-10-31%'
-- GROUP BY ROLLUP (perimetre, categorie) ORDER BY 1, 2;
