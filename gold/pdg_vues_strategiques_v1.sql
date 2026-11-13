-- ============================================================================
-- pdg-vues-strategiques-v3.sql  (12/11/2026)
-- v3 : type de client (catégorie CRM) dans toutes les vues, pour le filtre
--   « Type de client » du tableau de bord de la direction. Les vues sont
--   supprimées puis recréées (colonnes ajoutées) ; Metabase les retrouve par
--   leur nom.
-- v2 : vocabulaire aligné sur tous les tableaux de bord : « commande payée »
--   (contrat signé, deposit réglé) au lieu de « vente », « deposit » au lieu
--   d'« acompte » ; valeur des commandes payées = deposits réellement payés.
--   Noms de colonnes inchangés (ventes, valeur_ventes, acomptes) pour ne pas
--   casser les questions Metabase ; libellés et commentaires mis à jour.
-- Couche « PDG » de DELTA : vues stratégiques documentées, lues par le
-- tableau de bord Metabase du PDG et interrogeables directement par une IA
-- (chaque vue et chaque colonne porte un commentaire en base).
--
-- Schéma pdg
--   pdg.v_ventes_installations_jour  commandes payées et installations UPYA par jour
--   pdg.v_collecte_jour              encaissements par jour (recharges, deposits)
--   pdg.v_portefeuille_jour          portefeuille par photo quotidienne
--   pdg.v_kpi_mensuel                synthèse mensuelle par entité, avec variations
--   pdg.dictionnaire                 définitions des indicateurs (pour l'IA)
--   rôle pdg_lecture                 accès en lecture seule au seul schéma pdg
--
-- Règles reprises du comité crédit (décisions du 12/11/2026) :
--   retard en jours consécutifs pour toutes les entités ; PAR = rapport de
--   sommes d'encours ; actif = ENABLED ou LOCKED ; perte à 180 jours.
--
-- Étape 0 (v2) : bi.collecte nomme « Deposit » les paiements initiaux (au lieu
--   d'« Acompte »), comme les tableaux de bord.
--
-- Exécution : tout le fichier d'un bloc dans pgAdmin. Puis, à part, donner un
-- mot de passe au rôle (voir la fin du fichier).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. bi.collecte : « Deposit » au lieu d'« Acompte » (fonction et données)
-- ----------------------------------------------------------------------------
DO $do$
DECLARE d text := pg_get_functiondef('bi.rafraichir_collecte()'::regprocedure);
BEGIN
    IF position($a$ELSE 'Acompte' END$a$ IN d) > 0 THEN
        EXECUTE replace(d, $a$ELSE 'Acompte' END$a$, $a$ELSE 'Deposit' END$a$);
    END IF;
END
$do$;
UPDATE bi.collecte SET type_paiement = 'Deposit' WHERE type_paiement = 'Acompte';

CREATE SCHEMA IF NOT EXISTS pdg;
DROP VIEW IF EXISTS pdg.v_kpi_mensuel, pdg.v_ventes_installations_jour, pdg.v_collecte_jour, pdg.v_portefeuille_jour CASCADE;
COMMENT ON SCHEMA pdg IS
'Vues stratégiques DELTA pour la direction générale (TEVIA, GREENO, NEoTCI). Lecture seule. Montants en FCFA. Commencer par pdg.dictionnaire puis pdg.v_kpi_mensuel.';


-- ----------------------------------------------------------------------------
-- 1. Commandes payées et installations par jour (contrats créés dans UPYA)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW pdg.v_ventes_installations_jour AS
WITH dep AS MATERIALIZED (
    SELECT contract_number::text AS numero_contrat, SUM(amount) AS montant
    FROM gold.unified_transactions
    WHERE normalized_reason = 'upfront_payment' AND COALESCE(ignore_payment, false) = false
    GROUP BY 1
),
inst AS MATERIALIZED (
    SELECT contract_number, MIN(deploy_date)::date AS d
    FROM silver.upya_assets
    WHERE deploy_date IS NOT NULL AND contract_number IS NOT NULL
    GROUP BY 1
),
c AS MATERIALIZED (
    SELECT c.contract_number,
           CASE WHEN upper(c.product_name) LIKE 'GREENO%' THEN 'GREENO' ELSE 'TEVIA' END AS entite,
           CASE WHEN upper(c.product_name) LIKE 'GREENO%' THEN 'upya_greeno' ELSE 'upya_tevia' END AS categorie,
           COALESCE(NULLIF(TRIM(c.product_name), ''), 'Non renseigné')         AS produit,
           CASE WHEN c.onboarding_status = 'Signed' THEN c.signing_date::date END AS date_vente,
           i.d                                                                  AS date_installation,
           COALESCE(dp.montant, 0)                                              AS valeur
    FROM silver.upya_contracts c
    LEFT JOIN inst i ON i.contract_number = c.contract_number
    LEFT JOIN dep dp ON dp.numero_contrat = c.contract_number
    WHERE c.contract_number !~ '^[NT][0-9]+$'           -- migrés SURGE exclus (anciennes ventes)
      AND c.updated_at >= (SELECT MAX(updated_at) FROM silver.upya_contracts) - INTERVAL '2 hours'
)
SELECT jour, entite, categorie, produit,
       SUM(ventes)::int          AS ventes,
       SUM(valeur_ventes)        AS valeur_ventes,
       SUM(installations)::int   AS installations
FROM (
    SELECT date_vente AS jour, entite, categorie, produit, 1 AS ventes, valeur AS valeur_ventes, 0 AS installations
    FROM c WHERE date_vente IS NOT NULL
    UNION ALL
    SELECT date_installation, entite, categorie, produit, 0, 0, 1
    FROM c WHERE date_installation IS NOT NULL
) x
GROUP BY 1, 2, 3, 4;

COMMENT ON COLUMN pdg.v_ventes_installations_jour.categorie IS 'Type de client (catégorie CRM) : upya_tevia et surge_tevia (Comité TEVIA), surge_zeci (ZECI, entité TEVIA hors comité), upya_greeno (GREENO), surge_neotci (NEoTCI)';
COMMENT ON VIEW pdg.v_ventes_installations_jour IS
'Commandes payées (contrats signés, deposit réglé) et installations (premier déploiement de kit) par jour, entité et produit. Contrats créés dans UPYA uniquement : les contrats migrés de SURGE (numéros T…, N…) sont exclus. Historique complet depuis l''ouverture d''UPYA. Colonnes ventes et valeur_ventes = commandes payées.';
COMMENT ON COLUMN pdg.v_ventes_installations_jour.jour IS 'Date de signature pour les commandes payées, date du premier déploiement pour les installations';
COMMENT ON COLUMN pdg.v_ventes_installations_jour.entite IS 'TEVIA ou GREENO (produit commençant par GREENO)';
COMMENT ON COLUMN pdg.v_ventes_installations_jour.ventes IS 'Commandes payées : nombre de contrats signés ce jour';
COMMENT ON COLUMN pdg.v_ventes_installations_jour.valeur_ventes IS 'Valeur des commandes payées : deposits réellement payés (tous paiements de deposit acceptés) par les commandes signées ce jour, en FCFA';
COMMENT ON COLUMN pdg.v_ventes_installations_jour.installations IS 'Nombre de kits installés ce jour';


-- ----------------------------------------------------------------------------
-- 2. Encaissements par jour
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW pdg.v_collecte_jour AS
SELECT date_paiement                    AS jour,
       entite,
       categorie,
       perimetre,
       type_paiement,
       COUNT(*)::int                    AS nb_paiements,
       COUNT(DISTINCT numero_contrat)::int AS nb_clients,
       SUM(montant)                     AS montant
FROM bi.collecte
GROUP BY 1, 2, 3, 4, 5;

COMMENT ON COLUMN pdg.v_collecte_jour.categorie IS 'Type de client (catégorie CRM) : upya_tevia et surge_tevia (Comité TEVIA), surge_zeci (ZECI, entité TEVIA hors comité), upya_greeno (GREENO), surge_neotci (NEoTCI)';
COMMENT ON VIEW pdg.v_collecte_jour IS
'Encaissements acceptés par jour depuis le 01/01/2025, par entité et type (Recharge = remboursement du crédit, Deposit = paiement initial). Paiements SURGE rattachés au numéro migré. Recalculée chaque nuit.';
COMMENT ON COLUMN pdg.v_collecte_jour.perimetre IS 'Comité TEVIA (upya_tevia + surge_tevia), Comité GREENO (upya_greeno) ou Hors comité (NEoTCI, ZECI)';
COMMENT ON COLUMN pdg.v_collecte_jour.type_paiement IS 'Recharge ou Deposit';
COMMENT ON COLUMN pdg.v_collecte_jour.montant IS 'Montant encaissé en FCFA';


-- ----------------------------------------------------------------------------
-- 3. Portefeuille par photo quotidienne
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW pdg.v_portefeuille_jour AS
SELECT i.date_photo                       AS jour,
       c.est_fin_mois,
       c.est_comite,
       i.entite,
       i.categorie,
       i.perimetre,
       SUM(i.nb_actifs)::int              AS actifs,
       SUM(i.encours)                     AS encours,
       SUM(i.encours_par30)               AS encours_par30,
       SUM(i.encours_par90)               AS encours_par90,
       SUM(i.encours_par180)              AS encours_par180,
       ROUND(SUM(i.encours_par30)  / NULLIF(SUM(i.encours), 0), 4) AS par30,
       ROUND(SUM(i.encours_par90)  / NULLIF(SUM(i.encours), 0), 4) AS par90,
       ROUND(SUM(i.encours_par180) / NULLIF(SUM(i.encours), 0), 4) AS par180,
       ROUND(SUM(i.encours_par30 - i.encours_par180)
             / NULLIF(SUM(i.encours - i.encours_par180), 0), 4)    AS par30_hors_perte,
       SUM(i.nb_fpd)::int                 AS nb_fpd,
       SUM(i.nb_fpd_evaluables)::int      AS nb_fpd_evaluables,
       ROUND(SUM(i.nb_fpd)::numeric / NULLIF(SUM(i.nb_fpd_evaluables), 0), 4) AS taux_fpd
FROM bi.indicateurs_jour i
JOIN bi.calendrier c USING (date_photo)
GROUP BY 1, 2, 3, 4, 5, 6;

COMMENT ON COLUMN pdg.v_portefeuille_jour.categorie IS 'Type de client (catégorie CRM) : upya_tevia et surge_tevia (Comité TEVIA), surge_zeci (ZECI, entité TEVIA hors comité), upya_greeno (GREENO), surge_neotci (NEoTCI)';
COMMENT ON VIEW pdg.v_portefeuille_jour IS
'État du portefeuille actif à chaque photo quotidienne (depuis le 01/10/2026), par entité. Actif = kit ENABLED ou LOCKED. Retard en jours consécutifs depuis la fin du crédit. PAR N = encours des clients en retard de plus de N jours / encours actif (ratio de 0 à 1). Attention : la bascule SURGE vers UPYA du 01/11/2026 rend octobre et novembre peu comparables pour NEoTCI.';
COMMENT ON COLUMN pdg.v_portefeuille_jour.jour IS 'Date de la photo (état de fin de journée)';
COMMENT ON COLUMN pdg.v_portefeuille_jour.est_fin_mois IS 'Dernier jour du mois';
COMMENT ON COLUMN pdg.v_portefeuille_jour.est_comite IS 'Jour du comité crédit (jeudi par défaut)';
COMMENT ON COLUMN pdg.v_portefeuille_jour.actifs IS 'Nombre de contrats actifs';
COMMENT ON COLUMN pdg.v_portefeuille_jour.encours IS 'Reste à payer des contrats actifs, en FCFA';
COMMENT ON COLUMN pdg.v_portefeuille_jour.par30 IS 'PAR30 global : part de l''encours portée par des clients en retard de plus de 30 jours, write-off compris (0 à 1)';
COMMENT ON COLUMN pdg.v_portefeuille_jour.par90 IS 'PAR90 (0 à 1)';
COMMENT ON COLUMN pdg.v_portefeuille_jour.par180 IS 'PAR180 : part de l''encours à 180 jours et plus, seuil de passage en perte (0 à 1)';
COMMENT ON COLUMN pdg.v_portefeuille_jour.par30_hors_perte IS 'PAR30 hors write-off : PAR30 calculé sans les contrats à 180 jours et plus (seuil de write-off), au numérateur comme au dénominateur ; qualité du portefeuille encore récupérable (0 à 1)';
COMMENT ON COLUMN pdg.v_portefeuille_jour.taux_fpd IS 'First payment default : actifs de plus de 30 jours n''ayant rien payé (ou moins d''une mensualité) au-delà du deposit, hors 120 jours et plus (0 à 1)';


-- ----------------------------------------------------------------------------
-- 4. Synthèse mensuelle par entité, avec variations
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW pdg.v_kpi_mensuel AS
WITH vi AS (
    SELECT date_trunc('month', jour)::date AS mois, entite, categorie,
           SUM(ventes) AS ventes, SUM(valeur_ventes) AS valeur_ventes, SUM(installations) AS installations
    FROM pdg.v_ventes_installations_jour GROUP BY 1, 2, 3
),
col AS (
    SELECT date_trunc('month', jour)::date AS mois, entite, categorie,
           SUM(montant) FILTER (WHERE type_paiement = 'Recharge') AS recharges,
           SUM(montant) FILTER (WHERE type_paiement = 'Deposit')  AS acomptes,
           SUM(montant)                                           AS encaissements
    FROM pdg.v_collecte_jour GROUP BY 1, 2, 3
),
pf AS (
    SELECT DISTINCT ON (date_trunc('month', jour), entite, categorie)
           date_trunc('month', jour)::date AS mois, entite, categorie, jour AS date_photo,
           actifs, encours, par30, par90, par180, par30_hors_perte, taux_fpd
    FROM pdg.v_portefeuille_jour
    ORDER BY date_trunc('month', jour), entite, categorie, jour DESC
),
m AS (
    SELECT COALESCE(vi.mois, col.mois, pf.mois)       AS mois,
           COALESCE(vi.entite, col.entite, pf.entite) AS entite,
           COALESCE(vi.categorie, col.categorie, pf.categorie) AS categorie,
           COALESCE(vi.ventes, 0)        AS ventes,
           COALESCE(vi.valeur_ventes, 0) AS valeur_ventes,
           COALESCE(vi.installations, 0) AS installations,
           COALESCE(col.recharges, 0)    AS recharges,
           COALESCE(col.acomptes, 0)     AS acomptes,
           COALESCE(col.encaissements, 0) AS encaissements,
           pf.date_photo, pf.actifs, pf.encours, pf.par30, pf.par90, pf.par180,
           pf.par30_hors_perte, pf.taux_fpd
    FROM vi
    FULL JOIN col ON col.mois = vi.mois AND col.entite = vi.entite AND col.categorie = vi.categorie
    FULL JOIN pf  ON pf.mois = COALESCE(vi.mois, col.mois) AND pf.entite = COALESCE(vi.entite, col.entite)
                 AND pf.categorie = COALESCE(vi.categorie, col.categorie)
)
SELECT m.*,
       (m.mois = date_trunc('month', CURRENT_DATE)::date)                         AS mois_en_cours,
       ROUND(m.ventes::numeric / NULLIF(LAG(m.ventes) OVER w, 0) - 1, 4)         AS var_ventes,
       ROUND(m.installations::numeric / NULLIF(LAG(m.installations) OVER w, 0) - 1, 4) AS var_installations,
       ROUND(m.encaissements / NULLIF(LAG(m.encaissements) OVER w, 0) - 1, 4)    AS var_encaissements,
       ROUND(m.par30 - LAG(m.par30) OVER w, 4)                                   AS var_par30_points
FROM m
WINDOW w AS (PARTITION BY m.entite, m.categorie ORDER BY m.mois);

COMMENT ON COLUMN pdg.v_kpi_mensuel.categorie IS 'Type de client (catégorie CRM) : upya_tevia et surge_tevia (Comité TEVIA), surge_zeci (ZECI, entité TEVIA hors comité), upya_greeno (GREENO), surge_neotci (NEoTCI)';
COMMENT ON VIEW pdg.v_kpi_mensuel IS
'Synthèse stratégique par mois et par entité : commandes payées (colonnes ventes, valeur_ventes), installations, encaissements (recharges, deposits dans la colonne acomptes), et portefeuille à la dernière photo du mois. Variations par rapport au mois précédent (var_* en ratio, 0.1 = +10 % ; var_par30_points en points de ratio). Le mois en cours est partiel (mois_en_cours = true) : ne pas le comparer tel quel au mois précédent. Portefeuille disponible depuis octobre 2026, encaissements depuis janvier 2025.';
COMMENT ON COLUMN pdg.v_kpi_mensuel.mois IS 'Premier jour du mois';
COMMENT ON COLUMN pdg.v_kpi_mensuel.encaissements IS 'Recharges + deposits encaissés dans le mois, en FCFA';
COMMENT ON COLUMN pdg.v_kpi_mensuel.date_photo IS 'Date de la photo de portefeuille retenue (dernière du mois)';
COMMENT ON COLUMN pdg.v_kpi_mensuel.mois_en_cours IS 'Mois non terminé : chiffres partiels';


-- ----------------------------------------------------------------------------
-- 5. Dictionnaire des indicateurs (contexte pour l'IA et les lecteurs)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pdg.dictionnaire (
    indicateur  text PRIMARY KEY,
    definition  text NOT NULL,
    calcul      text NOT NULL,
    source      text NOT NULL
);
TRUNCATE pdg.dictionnaire;
INSERT INTO pdg.dictionnaire VALUES
('Entité', 'TEVIA, GREENO ou NEoTCI. TEVIA comprend upya_tevia, surge_tevia et surge_zeci ; GREENO = upya_greeno ; NEoTCI = surge_neotci (migré dans UPYA le 01/11/2026).', 'Catégorie CRM du contrat', 'bi.ref_source_crm'),
('Contrat actif', 'Contrat PAYG activé dont le kit est ENABLED (fonctionne) ou LOCKED (coupé faute de paiement).', 'statut ENABLED ou LOCKED', 'pdg.v_portefeuille_jour.actifs'),
('Encours', 'Ce que les clients actifs doivent encore payer jusqu''à la fin de leur contrat.', 'Somme des restes à payer des actifs', 'pdg.v_portefeuille_jour.encours'),
('Jours de retard', 'Jours consécutifs écoulés depuis la date jusqu''à laquelle le client avait payé ; retombe à 0 dès qu''il recharge. Même règle pour toutes les entités depuis le 12/11/2026.', 'date de la photo − fin du crédit', 'bi.v_portefeuille_date'),
('PAR N', 'Part de l''encours portée par des clients en retard de plus de N jours. Mesure en montant, pas en nombre de clients.', 'encours des clients en retard > N j / encours actif', 'pdg.v_portefeuille_jour'),
('PAR30 global', 'PAR30 sur tout l''encours actif, contrats à 180 jours et plus compris. Colonne par30.', 'encours > 30 j / encours actif', 'pdg.v_portefeuille_jour.par30'),
('PAR180', 'Part de l''encours à 180 jours et plus : seuil de write-off.', 'encours ≥ 180 j / encours actif', 'pdg.v_portefeuille_jour.par180'),
('PAR30 hors write-off', 'PAR30 sur le seul portefeuille encore récupérable, sans les contrats à 180 jours et plus (seuil de write-off). Colonne par30_hors_perte.', '(encours > 30 j − encours ≥ 180 j) / (encours − encours ≥ 180 j)', 'pdg.v_portefeuille_jour.par30_hors_perte'),
('Taux FPD', 'First payment default : clients actifs de plus de 30 jours qui n''ont rien payé, ou moins d''une mensualité, au-delà du deposit. Hors 120 jours et plus.', 'FPD / actifs évaluables', 'pdg.v_portefeuille_jour.taux_fpd'),
('Commande payée', 'Contrat signé dans UPYA (statut Signed, deposit réglé), daté du jour de signature. Les migrés SURGE ne sont pas des commandes payées. Colonne ventes.', 'Nombre de contrats signés', 'pdg.v_ventes_installations_jour'),
('Valeur des commandes payées', 'Deposits réellement payés par les commandes payées (tous paiements de deposit acceptés). Colonne valeur_ventes.', 'Somme des deposits payés', 'pdg.v_ventes_installations_jour'),
('Installation', 'Premier déploiement d''un kit pour le contrat.', 'Nombre de contrats au premier déploiement', 'pdg.v_ventes_installations_jour'),
('Recharge', 'Paiement de remboursement du crédit par le client.', 'Somme des paiements acceptés de type recharge', 'pdg.v_collecte_jour'),
('Deposit', 'Paiement initial versé à la commande, parfois en plusieurs fois (GREENO surtout).', 'Somme des paiements de type deposit', 'pdg.v_collecte_jour'),
('Photo', 'État du portefeuille enregistré chaque nuit ; le passé ne se réécrit pas. Historique depuis le 01/10/2026.', 'bi.calendrier', 'pdg.v_portefeuille_jour.jour');
COMMENT ON TABLE pdg.dictionnaire IS 'Définitions des indicateurs DELTA. À lire en premier par toute IA qui interroge le schéma pdg.';


-- ----------------------------------------------------------------------------
-- 6. Rôle en lecture seule pour le PDG et ses outils d'IA
--    (schéma pdg uniquement ; requêtes limitées à 60 secondes)
-- ----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pdg_lecture') THEN
        CREATE ROLE pdg_lecture LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
    END IF;
END $$;
ALTER ROLE pdg_lecture SET statement_timeout = '60s';
ALTER ROLE pdg_lecture SET default_transaction_read_only = on;
ALTER ROLE pdg_lecture SET search_path = pdg;
GRANT USAGE ON SCHEMA pdg TO pdg_lecture, role_read;
GRANT SELECT ON ALL TABLES IN SCHEMA pdg TO pdg_lecture, role_read;
-- Les vues pdg lisent bi et silver avec les droits de leur propriétaire :
-- pdg_lecture n'a pas besoin d'accès direct à ces schémas.

-- Contrôles
SELECT * FROM pdg.v_kpi_mensuel WHERE mois >= DATE '2026-09-01' ORDER BY entite, mois;
SELECT * FROM pdg.v_portefeuille_jour ORDER BY jour DESC, entite LIMIT 6;

-- À part, une fois, par toi seul : donner un mot de passe au rôle, puis le
-- transmettre au PDG par un canal sûr.
--   ALTER ROLE pdg_lecture PASSWORD '<mot de passe choisi>';
