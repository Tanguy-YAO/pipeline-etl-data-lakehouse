-- ============================================================================
-- recouvrement-attribution-neotci-v2.1.sql  (09/11/2026, v2.1 le 11/11/2026)
-- v2.1 : retrait du re-partage automatique ; table d'attribution protégée.
-- Ajustements de l'app de recouvrement NEoTCI demandés le 09/11/2026 au soir.
--
-- Attribution
--   * À jour et retard de 1 à 90 jours (tranches 0 à 3) : partagés entre les
--     3 agents, comme en v1 (serpentin par tranche, nombre et encours équilibrés).
--   * Plus de 90 jours (tranches 4 à 7, retard inconnu compris) : Me EBLOTIE.
--   * Toujours figé pour le mois ; une entrée en cours de mois va à l'agent le
--     moins chargé de sa tranche, ou à Me EBLOTIE au delà de 90 jours.
--   * Nom corrigé : Ludivine ABBY.
--
-- Vue contrats_neotci
--   * Tranches renommées : Current, PAR 1-30, PAR 31-60, PAR 61-90, PAR 91-120,
--     PAR 121-150, PAR 151-179, PAR 180+ (TEVIA et GREENO ne changent pas).
--   * Ancienne colonne jours_retard retirée ; solde_jours devient jours_retard,
--     signe inversé : positif = jours de retard, négatif = jours de crédit
--     restants (client en avance). Exemple : solde_jours −3 → jours_retard 3.
--   * Retirer et renommer des colonnes oblige à DROP puis CREATE de la vue :
--     droits de lucien remis à la fin ; AppSheet : « Regenerate structure ».
--
-- Lancer le fichier d'un bloc.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Agents : rôle, nom corrigé, Me EBLOTIE
-- ---------------------------------------------------------------------------
ALTER TABLE recouvrement.agents_neotci ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'agent';

UPDATE recouvrement.agents_neotci SET nom_agent = 'Ludivine ABBY' WHERE code_agent = 'NEO-03';

INSERT INTO recouvrement.agents_neotci (code_agent, nom_agent, ordre, role)
VALUES ('NEO-SUP', 'Me EBLOTIE', 99, 'superviseur')
ON CONFLICT (code_agent) DO UPDATE SET nom_agent = EXCLUDED.nom_agent, role = EXCLUDED.role;


-- ---------------------------------------------------------------------------
-- 2. Fonction d'attribution
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recouvrement.attribuer_neotci()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    m    date := date_trunc('month', CURRENT_DATE)::date;
    na   int;
    sup  text;
BEGIN
    SELECT COUNT(*) INTO na FROM recouvrement.agents_neotci WHERE actif AND role = 'agent';
    SELECT code_agent INTO sup FROM recouvrement.agents_neotci WHERE actif AND role = 'superviseur'
    ORDER BY ordre LIMIT 1;
    IF na = 0 OR sup IS NULL THEN RETURN; END IF;

    -- a. Partage complet, une fois par mois
    IF NOT EXISTS (SELECT 1 FROM recouvrement.attribution_neotci WHERE mois = m) THEN
        INSERT INTO recouvrement.attribution_neotci
            (mois, numero_contrat, code_agent, tranche_ordre, tranche_retard, encours_attribution, mode)
        WITH ag AS (
            SELECT code_agent, ROW_NUMBER() OVER (ORDER BY ordre) AS k
            FROM recouvrement.agents_neotci WHERE actif AND role = 'agent'
        ),
        c AS (
            SELECT numero_contrat, tranche_ordre, tranche_retard, reste_a_payer,
                   ROW_NUMBER() OVER (PARTITION BY tranche_ordre
                                      ORDER BY reste_a_payer DESC NULLS LAST, numero_contrat) - 1 AS r
            FROM recouvrement.contrats
            WHERE categorie = 'surge_neotci' AND tranche_ordre BETWEEN 0 AND 3
        )
        SELECT m, c.numero_contrat, ag.code_agent, c.tranche_ordre, c.tranche_retard, c.reste_a_payer, 'partage du mois'
        FROM c
        JOIN ag ON ag.k = CASE WHEN (c.r / na) % 2 = 0 THEN c.r % na + 1 ELSE na - c.r % na END
        UNION ALL
        SELECT m, numero_contrat, sup, tranche_ordre, tranche_retard, reste_a_payer, 'partage du mois'
        FROM recouvrement.contrats
        WHERE categorie = 'surge_neotci' AND (tranche_ordre IS NULL OR tranche_ordre > 3);
        RETURN;
    END IF;

    -- b. Entrées en cours de mois, au delà de 90 jours : Me EBLOTIE
    INSERT INTO recouvrement.attribution_neotci
        (mois, numero_contrat, code_agent, tranche_ordre, tranche_retard, encours_attribution, mode)
    SELECT m, c.numero_contrat, sup, c.tranche_ordre, c.tranche_retard, c.reste_a_payer, 'entrée en cours de mois'
    FROM recouvrement.contrats c
    WHERE c.categorie = 'surge_neotci' AND (c.tranche_ordre IS NULL OR c.tranche_ordre > 3)
      AND NOT EXISTS (SELECT 1 FROM recouvrement.attribution_neotci a
                      WHERE a.mois = m AND a.numero_contrat = c.numero_contrat);

    -- c. Entrées en cours de mois, jusqu'à 90 jours : agent le moins chargé de la tranche
    INSERT INTO recouvrement.attribution_neotci
        (mois, numero_contrat, code_agent, tranche_ordre, tranche_retard, encours_attribution, mode)
    WITH nouveaux AS (
        SELECT c.numero_contrat, c.tranche_ordre, c.tranche_retard, c.reste_a_payer,
               ROW_NUMBER() OVER (PARTITION BY c.tranche_ordre
                                  ORDER BY c.reste_a_payer DESC NULLS LAST, c.numero_contrat) - 1 AS r
        FROM recouvrement.contrats c
        WHERE c.categorie = 'surge_neotci' AND c.tranche_ordre BETWEEN 0 AND 3
          AND NOT EXISTS (SELECT 1 FROM recouvrement.attribution_neotci a
                          WHERE a.mois = m AND a.numero_contrat = c.numero_contrat)
    ),
    charge AS (
        SELECT t.tranche_ordre, g.code_agent,
               ROW_NUMBER() OVER (PARTITION BY t.tranche_ordre
                                  ORDER BY COUNT(a.numero_contrat), COALESCE(SUM(a.encours_attribution), 0), g.ordre) - 1 AS k
        FROM (SELECT DISTINCT tranche_ordre FROM nouveaux) t
        CROSS JOIN recouvrement.agents_neotci g
        LEFT JOIN recouvrement.attribution_neotci a
               ON a.mois = m AND a.code_agent = g.code_agent AND a.tranche_ordre = t.tranche_ordre
        WHERE g.actif AND g.role = 'agent'
        GROUP BY t.tranche_ordre, g.code_agent, g.ordre
    )
    SELECT m, n.numero_contrat, ch.code_agent, n.tranche_ordre, n.tranche_retard, n.reste_a_payer, 'entrée en cours de mois'
    FROM nouveaux n
    JOIN charge ch ON ch.tranche_ordre = n.tranche_ordre AND ch.k = n.r % na;
END;
$$;


-- ---------------------------------------------------------------------------
-- 3. Partage du mois : RETIRÉ le 11/11/2026
--    Ce bloc effaçait le partage du mois en cours et le refaisait. Relancé le
--    11/11 à 12h31, il a changé l'agent d'une partie des clients en pleine
--    journée. Le partage est fait uniquement par le pipeline (premier
--    rafraîchissement du mois), et la table est protégée (section 6).
--    Réattribution volontaire, en connaissance de cause seulement :
--      BEGIN;
--      SET LOCAL recouvrement.reattribution = 'oui';
--      DELETE FROM recouvrement.attribution_neotci WHERE mois = date_trunc('month', CURRENT_DATE)::date;
--      SELECT recouvrement.attribuer_neotci();
--      COMMIT;
-- ---------------------------------------------------------------------------
-- 4. Vue lue par l'app NEoTCI
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS recouvrement.contrats_neotci;
CREATE VIEW recouvrement.contrats_neotci AS
SELECT
    c.numero_contrat, c.entite, c.source, c.categorie,
    c.numero_client, c.nom_client, c.telephone_1, c.telephone_2,
    c.code_agent, c.nom_agent, c.produit, c.numero_kit,
    c.region, c.date_paiement_acompte, c.date_activation, c.age_jours,
    c.mois_ecoules, c.premiere_echeance, c.prochaine_echeance, c.derniere_maj_statut,
    c.jours_credit_restants,
    -c.solde_jours                                  AS jours_retard,      -- v2 : ex solde_jours, signe inversé
    c.expire_sous_3_jours, c.statut_contrat,
    c.tranche_ordre,
    CASE c.tranche_ordre
        WHEN 0 THEN 'Current'
        WHEN 1 THEN 'PAR 1-30'
        WHEN 2 THEN 'PAR 31-60'
        WHEN 3 THEN 'PAR 61-90'
        WHEN 4 THEN 'PAR 91-120'
        WHEN 5 THEN 'PAR 121-150'
        WHEN 6 THEN 'PAR 151-179'
        ELSE 'PAR 180+'
    END                                             AS tranche_retard,
    c.perte_seuil_efa, c.perte_seuil_credit,
    c.jours_retard_inconnu, c.jours_manques_cumules, c.valeur_contrat, c.acompte,
    c.mensualite, c.tarif_journalier, c.total_paye, c.reste_a_payer,
    c.pct_rembourse, c.nb_mois_payes, c.mensualites_restantes, c.attendu_a_date,
    c.arriere, c.date_dernier_paiement, c.montant_dernier_paiement, c.jours_depuis_dernier_paiement,
    c.nb_paiements, c.paye_30_derniers_jours, c.source_calculee_le, c.rafraichi_le,
    a.code_agent                                    AS code_agent_recouvrement,
    COALESCE(g.nom_agent, 'Non attribué')           AS agent_recouvrement,
    CASE a.tranche_ordre
        WHEN 0 THEN 'Current'     WHEN 1 THEN 'PAR 1-30'    WHEN 2 THEN 'PAR 31-60'
        WHEN 3 THEN 'PAR 61-90'   WHEN 4 THEN 'PAR 91-120'  WHEN 5 THEN 'PAR 121-150'
        WHEN 6 THEN 'PAR 151-179' ELSE 'PAR 180+'
    END                                             AS tranche_a_l_attribution,
    a.attribue_le
FROM recouvrement.contrats c
LEFT JOIN recouvrement.attribution_neotci a
       ON a.mois = date_trunc('month', CURRENT_DATE)::date AND a.numero_contrat = c.numero_contrat
LEFT JOIN recouvrement.agents_neotci g ON g.code_agent = a.code_agent
WHERE c.categorie = 'surge_neotci';

GRANT SELECT ON recouvrement.contrats_neotci TO lucien;

COMMIT;


-- ---------------------------------------------------------------------------
-- 5. Contrôles
-- ---------------------------------------------------------------------------
-- a. Par tranche et par agent : tranches 0 à 3 partagées entre les 3 agents,
--    tranches 4 à 7 toutes chez Me EBLOTIE
SELECT tranche_ordre, tranche_retard, agent_recouvrement,
       COUNT(*) AS clients, ROUND(SUM(reste_a_payer)) AS encours
FROM recouvrement.contrats_neotci
GROUP BY tranche_ordre, tranche_retard, agent_recouvrement
ORDER BY tranche_ordre, agent_recouvrement;

-- b. Totaux par agent (la dernière ligne est le total général)
SELECT agent_recouvrement, COUNT(*) AS clients, ROUND(SUM(reste_a_payer)) AS encours
FROM recouvrement.contrats_neotci
GROUP BY ROLLUP (agent_recouvrement) ORDER BY 1 NULLS LAST;

-- c. jours_retard (ex solde_jours inversé) par tranche : positif en retard, négatif ou nul en Current
SELECT tranche_retard, MIN(jours_retard), MAX(jours_retard)
FROM recouvrement.contrats_neotci GROUP BY tranche_ordre, tranche_retard ORDER BY tranche_ordre;


-- ---------------------------------------------------------------------------
-- Ajout du 09/11/2026 (exécuté en base) : colonne solde_jours remise en fin de vue
-- pour la compatibilité AppSheet.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW recouvrement.contrats_neotci AS
SELECT
    c.numero_contrat, c.entite, c.source, c.categorie,
    c.numero_client, c.nom_client, c.telephone_1, c.telephone_2,
    c.code_agent, c.nom_agent, c.produit, c.numero_kit,
    c.region, c.date_paiement_acompte, c.date_activation, c.age_jours,
    c.mois_ecoules, c.premiere_echeance, c.prochaine_echeance, c.derniere_maj_statut,
    c.jours_credit_restants,
    -c.solde_jours                                  AS jours_retard,      -- v2 : ex solde_jours, signe inversé
    c.expire_sous_3_jours, c.statut_contrat,
    c.tranche_ordre,
    CASE c.tranche_ordre
        WHEN 0 THEN 'Current'
        WHEN 1 THEN 'PAR 1-30'
        WHEN 2 THEN 'PAR 31-60'
        WHEN 3 THEN 'PAR 61-90'
        WHEN 4 THEN 'PAR 91-120'
        WHEN 5 THEN 'PAR 121-150'
        WHEN 6 THEN 'PAR 151-179'
        ELSE 'PAR 180+'
    END                                             AS tranche_retard,
    c.perte_seuil_efa, c.perte_seuil_credit,
    c.jours_retard_inconnu, c.jours_manques_cumules, c.valeur_contrat, c.acompte,
    c.mensualite, c.tarif_journalier, c.total_paye, c.reste_a_payer,
    c.pct_rembourse, c.nb_mois_payes, c.mensualites_restantes, c.attendu_a_date,
    c.arriere, c.date_dernier_paiement, c.montant_dernier_paiement, c.jours_depuis_dernier_paiement,
    c.nb_paiements, c.paye_30_derniers_jours, c.source_calculee_le, c.rafraichi_le,
    a.code_agent                                    AS code_agent_recouvrement,
    COALESCE(g.nom_agent, 'Non attribué')           AS agent_recouvrement,
    CASE a.tranche_ordre
        WHEN 0 THEN 'Current'     WHEN 1 THEN 'PAR 1-30'    WHEN 2 THEN 'PAR 31-60'
        WHEN 3 THEN 'PAR 61-90'   WHEN 4 THEN 'PAR 91-120'  WHEN 5 THEN 'PAR 121-150'
        WHEN 6 THEN 'PAR 151-179' ELSE 'PAR 180+'
    END                                             AS tranche_a_l_attribution,
    a.attribue_le,
    c.solde_jours                                   AS solde_jours   -- compatibilité AppSheet (à masquer), valeur d'origine
FROM recouvrement.contrats c
LEFT JOIN recouvrement.attribution_neotci a
       ON a.mois = date_trunc('month', CURRENT_DATE)::date AND a.numero_contrat = c.numero_contrat
LEFT JOIN recouvrement.agents_neotci g ON g.code_agent = a.code_agent
WHERE c.categorie = 'surge_neotci';

-- Contrôle
SELECT COUNT(*), MIN(solde_jours), MAX(jours_retard) FROM recouvrement.contrats_neotci;


-- ---------------------------------------------------------------------------
-- 6. Protection de l'attribution (11/11/2026)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recouvrement.proteger_attribution_neotci()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_setting('recouvrement.reattribution', true) IS DISTINCT FROM 'oui' THEN
        RAISE EXCEPTION 'Attribution NEoTCI figée : % refusé sur recouvrement.attribution_neotci. '
                        'Pour une réattribution voulue : SET LOCAL recouvrement.reattribution = ''oui''; dans la même transaction.', TG_OP;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_proteger_attribution_neotci ON recouvrement.attribution_neotci;
CREATE TRIGGER trg_proteger_attribution_neotci
    BEFORE DELETE OR UPDATE OR TRUNCATE ON recouvrement.attribution_neotci
    FOR EACH STATEMENT
    EXECUTE FUNCTION recouvrement.proteger_attribution_neotci();

-- Contrôle : doit échouer avec le message « Attribution NEoTCI figée »
-- DELETE FROM recouvrement.attribution_neotci WHERE false;
