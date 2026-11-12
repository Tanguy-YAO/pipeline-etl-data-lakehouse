-- ============================================================================
-- pdg-vues-strategiques-v1.sql  (12/11/2026)
-- Couche « PDG » de DELTA : vues stratégiques documentées, lues par le
-- tableau de bord Metabase du PDG et interrogeables directement par une IA
-- (chaque vue et chaque colonne porte un commentaire en base).
--
-- Schéma pdg
--   pdg.v_ventes_installations_jour  ventes et installations UPYA par jour
--   pdg.v_collecte_jour              encaissements par jour (recharges, acomptes)
--   pdg.v_portefeuille_jour          portefeuille par photo quotidienne
--   pdg.v_kpi_mensuel                synthèse mensuelle par entité, avec variations
--   pdg.dictionnaire                 définitions des indicateurs (pour l'IA)
--   rôle pdg_lecture                 accès en lecture seule au seul schéma pdg
--
-- Règles reprises du comité crédit (décisions du 12/11/2026) :
--   retard en jours consécutifs pour toutes les entités ; PAR = rapport de
--   sommes d'encours ; actif = ENABLED ou LOCKED ; perte à 180 jours.
--
-- Exécution : tout le fichier d'un bloc dans pgAdmin. Puis, à part, donner un
-- mot de passe au rôle (voir la fin du fichier).
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS pdg;
COMMENT ON SCHEMA pdg IS
'Vues stratégiques DELTA pour la direction générale (TEVIA, GREENO, NEoTCI). Lecture seule. Montants en FCFA. Commencer par pdg.dictionnaire puis pdg.v_kpi_mensuel.';


-- ----------------------------------------------------------------------------
-- 1. Ventes et installations par jour (contrats créés dans UPYA)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW pdg.v_ventes_installations_jour AS
WITH inst AS MATERIALIZED (
    SELECT contract_number, MIN(deploy_date)::date AS d
    FROM silver.upya_assets
    WHERE deploy_date IS NOT NULL AND contract_number IS NOT NULL
    GROUP BY 1
),
c AS MATERIALIZED (
    SELECT c.contract_number,
           CASE WHEN upper(c.product_name) LIKE 'GREENO%' THEN 'GREENO' ELSE 'TEVIA' END AS entite,
           COALESCE(NULLIF(TRIM(c.product_name), ''), 'Non renseigné')         AS produit,
           CASE WHEN c.onboarding_status = 'Signed' THEN c.signing_date::date END AS date_vente,
           i.d                                                                  AS date_installation,
           COALESCE(c.total_cost, 0)                                            AS valeur
    FROM silver.upya_contracts c
    LEFT JOIN inst i ON i.contract_number = c.contract_number
    WHERE c.contract_number !~ '^[NT][0-9]+$'           -- migrés SURGE exclus (anciennes ventes)
      AND c.updated_at >= (SELECT MAX(updated_at) FROM silver.upya_contracts) - INTERVAL '2 hours'
)
SELECT jour, entite, produit,
       SUM(ventes)::int          AS ventes,
       SUM(valeur_ventes)        AS valeur_ventes,
       SUM(installations)::int   AS installations
FROM (
    SELECT date_vente AS jour, entite, produit, 1 AS ventes, valeur AS valeur_ventes, 0 AS installations
    FROM c WHERE date_vente IS NOT NULL
    UNION ALL
    SELECT date_installation, entite, produit, 0, 0, 1
    FROM c WHERE date_installation IS NOT NULL
) x
GROUP BY 1, 2, 3;

COMMENT ON VIEW pdg.v_ventes_installations_jour IS
'Ventes (contrats signés) et installations (premier déploiement de kit) par jour, entité et produit. Contrats créés dans UPYA uniquement : les contrats migrés de SURGE (numéros T…, N…) sont exclus. Historique complet depuis l''ouverture d''UPYA.';
COMMENT ON COLUMN pdg.v_ventes_installations_jour.jour IS 'Date de signature pour les ventes, date du premier déploiement pour les installations';
COMMENT ON COLUMN pdg.v_ventes_installations_jour.entite IS 'TEVIA ou GREENO (produit commençant par GREENO)';
COMMENT ON COLUMN pdg.v_ventes_installations_jour.ventes IS 'Nombre de contrats signés ce jour';
COMMENT ON COLUMN pdg.v_ventes_installations_jour.valeur_ventes IS 'Valeur totale des contrats signés ce jour, en FCFA';
COMMENT ON COLUMN pdg.v_ventes_installations_jour.installations IS 'Nombre de kits installés ce jour';


-- ----------------------------------------------------------------------------
-- 2. Encaissements par jour
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW pdg.v_collecte_jour AS
SELECT date_paiement                    AS jour,
       entite,
       perimetre,
       type_paiement,
       COUNT(*)::int                    AS nb_paiements,
       COUNT(DISTINCT numero_contrat)::int AS nb_clients,
       SUM(montant)                     AS montant
FROM bi.collecte
GROUP BY 1, 2, 3, 4;

COMMENT ON VIEW pdg.v_collecte_jour IS
'Encaissements acceptés par jour depuis le 01/01/2025, par entité et type (Recharge = remboursement du crédit, Acompte = paiement initial). Paiements SURGE rattachés au numéro migré. Recalculée chaque nuit.';
COMMENT ON COLUMN pdg.v_collecte_jour.perimetre IS 'Comité TEVIA (upya_tevia + surge_tevia), Comité GREENO (upya_greeno) ou Hors comité (NEoTCI, ZECI)';
COMMENT ON COLUMN pdg.v_collecte_jour.type_paiement IS 'Recharge ou Acompte';
COMMENT ON COLUMN pdg.v_collecte_jour.montant IS 'Montant encaissé en FCFA';


-- ----------------------------------------------------------------------------
-- 3. Portefeuille par photo quotidienne
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW pdg.v_portefeuille_jour AS
SELECT i.date_photo                       AS jour,
       c.est_fin_mois,
       c.est_comite,
       i.entite,
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
GROUP BY 1, 2, 3, 4;

COMMENT ON VIEW pdg.v_portefeuille_jour IS
'État du portefeuille actif à chaque photo quotidienne (depuis le 01/10/2026), par entité. Actif = kit ENABLED ou LOCKED. Retard en jours consécutifs depuis la fin du crédit. PAR N = encours des clients en retard de plus de N jours / encours actif (ratio de 0 à 1). Attention : la bascule SURGE vers UPYA du 01/11/2026 rend octobre et novembre peu comparables pour NEoTCI.';
COMMENT ON COLUMN pdg.v_portefeuille_jour.jour IS 'Date de la photo (état de fin de journée)';
COMMENT ON COLUMN pdg.v_portefeuille_jour.est_fin_mois IS 'Dernier jour du mois';
COMMENT ON COLUMN pdg.v_portefeuille_jour.est_comite IS 'Jour du comité crédit (jeudi par défaut)';
COMMENT ON COLUMN pdg.v_portefeuille_jour.actifs IS 'Nombre de contrats actifs';
COMMENT ON COLUMN pdg.v_portefeuille_jour.encours IS 'Reste à payer des contrats actifs, en FCFA';
COMMENT ON COLUMN pdg.v_portefeuille_jour.par30 IS 'PAR30 : part de l''encours portée par des clients en retard de plus de 30 jours (0 à 1)';
COMMENT ON COLUMN pdg.v_portefeuille_jour.par90 IS 'PAR90 (0 à 1)';
COMMENT ON COLUMN pdg.v_portefeuille_jour.par180 IS 'PAR180 : part de l''encours à 180 jours et plus, seuil de passage en perte (0 à 1)';
COMMENT ON COLUMN pdg.v_portefeuille_jour.par30_hors_perte IS 'PAR30 calculé sans les contrats à 180 jours et plus : qualité du portefeuille encore récupérable (0 à 1)';
COMMENT ON COLUMN pdg.v_portefeuille_jour.taux_fpd IS 'First payment default : actifs de plus de 30 jours n''ayant rien payé (ou moins d''une mensualité) au-delà de l''acompte, hors 120 jours et plus (0 à 1)';


-- ----------------------------------------------------------------------------
-- 4. Synthèse mensuelle par entité, avec variations
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW pdg.v_kpi_mensuel AS
WITH vi AS (
    SELECT date_trunc('month', jour)::date AS mois, entite,
           SUM(ventes) AS ventes, SUM(valeur_ventes) AS valeur_ventes, SUM(installations) AS installations
    FROM pdg.v_ventes_installations_jour GROUP BY 1, 2
),
col AS (
    SELECT date_trunc('month', jour)::date AS mois, entite,
           SUM(montant) FILTER (WHERE type_paiement = 'Recharge') AS recharges,
           SUM(montant) FILTER (WHERE type_paiement = 'Acompte')  AS acomptes,
           SUM(montant)                                           AS encaissements
    FROM pdg.v_collecte_jour GROUP BY 1, 2
),
pf AS (
    SELECT DISTINCT ON (date_trunc('month', jour), entite)
           date_trunc('month', jour)::date AS mois, entite, jour AS date_photo,
           actifs, encours, par30, par90, par180, par30_hors_perte, taux_fpd
    FROM pdg.v_portefeuille_jour
    ORDER BY date_trunc('month', jour), entite, jour DESC
),
m AS (
    SELECT COALESCE(vi.mois, col.mois, pf.mois)       AS mois,
           COALESCE(vi.entite, col.entite, pf.entite) AS entite,
           COALESCE(vi.ventes, 0)        AS ventes,
           COALESCE(vi.valeur_ventes, 0) AS valeur_ventes,
           COALESCE(vi.installations, 0) AS installations,
           COALESCE(col.recharges, 0)    AS recharges,
           COALESCE(col.acomptes, 0)     AS acomptes,
           COALESCE(col.encaissements, 0) AS encaissements,
           pf.date_photo, pf.actifs, pf.encours, pf.par30, pf.par90, pf.par180,
           pf.par30_hors_perte, pf.taux_fpd
    FROM vi
    FULL JOIN col ON col.mois = vi.mois AND col.entite = vi.entite
    FULL JOIN pf  ON pf.mois = COALESCE(vi.mois, col.mois) AND pf.entite = COALESCE(vi.entite, col.entite)
)
SELECT m.*,
       (m.mois = date_trunc('month', CURRENT_DATE)::date)                         AS mois_en_cours,
       ROUND(m.ventes::numeric / NULLIF(LAG(m.ventes) OVER w, 0) - 1, 4)         AS var_ventes,
       ROUND(m.installations::numeric / NULLIF(LAG(m.installations) OVER w, 0) - 1, 4) AS var_installations,
       ROUND(m.encaissements / NULLIF(LAG(m.encaissements) OVER w, 0) - 1, 4)    AS var_encaissements,
       ROUND(m.par30 - LAG(m.par30) OVER w, 4)                                   AS var_par30_points
FROM m
WINDOW w AS (PARTITION BY m.entite ORDER BY m.mois);

COMMENT ON VIEW pdg.v_kpi_mensuel IS
'Synthèse stratégique par mois et par entité : ventes, installations, encaissements, et portefeuille à la dernière photo du mois. Variations par rapport au mois précédent (var_* en ratio, 0.1 = +10 % ; var_par30_points en points de ratio). Le mois en cours est partiel (mois_en_cours = true) : ne pas le comparer tel quel au mois précédent. Portefeuille disponible depuis octobre 2026, encaissements depuis janvier 2025.';
COMMENT ON COLUMN pdg.v_kpi_mensuel.mois IS 'Premier jour du mois';
COMMENT ON COLUMN pdg.v_kpi_mensuel.encaissements IS 'Recharges + acomptes encaissés dans le mois, en FCFA';
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
('PAR180', 'Part de l''encours à 180 jours et plus : seuil de passage en perte.', 'encours ≥ 180 j / encours actif', 'pdg.v_portefeuille_jour.par180'),
('PAR30 hors perte', 'PAR30 sur le seul portefeuille encore récupérable (sans les 180 jours et plus).', '(encours > 30 j − encours ≥ 180 j) / (encours − encours ≥ 180 j)', 'pdg.v_portefeuille_jour.par30_hors_perte'),
('Taux FPD', 'First payment default : clients actifs de plus de 30 jours qui n''ont rien payé, ou moins d''une mensualité, au-delà de l''acompte. Hors 120 jours et plus.', 'FPD / actifs évaluables', 'pdg.v_portefeuille_jour.taux_fpd'),
('Vente', 'Contrat signé dans UPYA (statut Signed), daté du jour de signature. Les migrés SURGE ne sont pas des ventes.', 'Nombre de contrats signés', 'pdg.v_ventes_installations_jour'),
('Installation', 'Premier déploiement d''un kit pour le contrat.', 'Nombre de contrats au premier déploiement', 'pdg.v_ventes_installations_jour'),
('Recharge', 'Paiement de remboursement du crédit par le client.', 'Somme des paiements acceptés de type recharge', 'pdg.v_collecte_jour'),
('Acompte', 'Paiement initial versé à la signature.', 'Somme des paiements de type acompte', 'pdg.v_collecte_jour'),
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
