-- delta/recouvrement-views.sql
-- Couche de service de l'application de recouvrement (AppSheet)
-- v2.1, 13/10/2026
--
-- Changement v2.1 : sous_prefecture, village, latitude et longitude retirées
--   (la région suffit à l'app).
--
-- Changements v2 :
--   * Toutes les colonnes renommées en français (table de correspondance
--     en fin de fichier).
--   * Nouvelles colonnes : prochaine_echeance, premiere_echeance,
--     mois_ecoules, nb_mois_payes.
--   * prochaine_echeance = next_status_update, vérifié sur l'extrait du
--     01/10/2026 : pour 585 contrats UPYA sur 621 (94 %), next_status_update
--     égale exactement date_activation + 30 jours (acompte) + jours achetés par
--     les recharges (mensualité = 30 jours). C'est donc la date de fin du
--     crédit acheté : à venir pour un contrat ENABLED, date de coupure passée
--     pour un contrat LOCKED.
--   * Même vérification : le crédit démarre à l'activation, pas au paiement de
--     l'acompte (écart de 1 à 6 jours avec paid_date). D'où
--     premiere_echeance = date_activation + 30 jours.
--
-- Pourquoi cette couche :
--   AppSheet lisait gold.unified_contracts en entier à chaque synchronisation
--   (85 000 lignes, toutes catégories, SURGE NEoTCI/ZECI compris), puis
--   calculait ses colonnes virtuelles ligne par ligne sur le téléphone de
--   l'agent. Ici le travail est fait une fois, côté PostgreSQL, et AppSheet ne
--   reçoit que les contrats à recouvrer, colonnes déjà calculées.
--
-- Architecture :
--   gold.unified_contracts ──┐
--                            ├─> recouvrement.mv_contrats   (vue matérialisée,
--   gold.unified_transactions┘    calcul unique, indexée, rafraîchie après
--                                 chaque mise à jour du pipeline)
--                                     │
--                     ┌───────────────┴───────────────┐
--         recouvrement.contrats_tevia      recouvrement.contrats_greeno
--         (vues simples : un filtre sur entite, lecture quasi instantanée)
--
-- Périmètre de mv_contrats :
--   PAYG, activé (registration_date renseignée), statut ENABLED ou LOCKED.
--   Catégories : upya_tevia, surge_tevia (portefeuille TEVIA), upya_greeno.
--   Exclus : PAID_OFF, REPOSSESSED, CANCELLED, FULL, surge_neotci, surge_zeci.
--
-- Règles de calcul :
--   * jours_retard = consecutive_locked_days, NULL traité comme 0.
--   * Tranches : À jour / 1-30 / 31-60 / 61-90 / 91-120 / 121-180 / 180+.
--     120 j = passage en perte au sens EFA/IFC ; 180 j = seuil du credit
--     manager. Le découpage 121-180 permet de lire les deux sans recalcul.
--   * mois_ecoules = FLOOR(age_jours / 30). Comme l'acompte couvre le premier
--     mois et que la mensualité n°k tombe à J+30k, mois_ecoules est aussi le
--     nombre de mensualités dues à date.
--   * nb_mois_payes = (total_paye - acompte) / mensualite, plancher 0, arrondi
--     à 2 décimales (une recharge partielle compte pour une fraction de mois).
--     Côté SURGE, total_paye peut inclure des pénalités de retard : le nombre
--     de mois y est donc légèrement surestimé.
--   * arriere = attendu à date - total payé, plancher 0. Attendu = acompte +
--     accrual journalier (mensualité/30) après 30 jours de grâce, plafonné à la
--     valeur du contrat. Même formule que gold.vw_payg_contracts et
--     gold.vw_efa_contracts : un seul calcul d'arriéré dans DELTA.
--   * Paiements : gold.unified_transactions, recharge + upfront_payment, hors
--     paiements ignorés.
--   * Téléphones : le 0 initial des numéros ivoiriens à 10 chiffres est perdu
--     au stockage numérique (778189604 au lieu de 0778189604). On le restaure.
--   * Localisation : région seule, préfixe retiré ("Région nawa" → "NAWA").
--   * Les colonnes dépendant de la date du jour sont figées à l'heure du
--     rafraîchissement, exposée dans rafraichi_le.
--   * prochaine_echeance est la vérité UPYA pour la coupure. Ne pas la
--     recalculer depuis nb_mois_payes : sur les contrats anciens, UPYA a
--     accordé plus de jours que le cash ne l'explique (ex. 000033809 :
--     21 000 XOF nets à 200 XOF/j = 105 jours, coupure réelle 188 jours plus
--     tard que prévu). Cause à investiguer (jours offerts, changement de
--     tarif, paiements absents de total_paid).
--
-- Points ouverts :
--   * Colonnes virtuelles AppSheet restantes à porter ici.
--   * Saisies de l'app (résultat d'appel, promesse) : une vue matérialisée est
--     en lecture seule, elles devront aller dans une table réelle du schéma.
--   * Rôle PostgreSQL utilisé par AppSheet, pour les droits (section 5).


-- ---------------------------------------------------------------------------
-- 0. Schéma (déjà renommé depuis credit_db le 13/10/2026)
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS recouvrement;


-- ---------------------------------------------------------------------------
-- 1. Nettoyage (ordre inverse des dépendances, sans CASCADE)
--    Ajouter ou renommer des colonnes impose de recréer la vue matérialisée.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS recouvrement.contrats_tevia;
DROP VIEW IF EXISTS recouvrement.contrats_greeno;
DROP MATERIALIZED VIEW IF EXISTS recouvrement.mv_contrats;


-- ---------------------------------------------------------------------------
-- 2. Vue matérialisée : un contrat à recouvrer par ligne
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW recouvrement.mv_contrats AS
WITH paiements AS (
    SELECT
        t.contract_number::text                                   AS numero_contrat,
        t.payment_date,
        t.amount,
        ROW_NUMBER() OVER (PARTITION BY t.contract_number
                           ORDER BY t.payment_date DESC, t.transaction_id DESC) AS rang
    FROM gold.unified_transactions t
    WHERE t.normalized_reason IN ('recharge', 'upfront_payment')
      AND COALESCE(t.ignore_payment, false) = false
),
synthese_paiements AS (
    SELECT
        numero_contrat,
        COUNT(*)                                                  AS nb_paiements,
        MAX(payment_date)::date                                   AS date_dernier_paiement,
        MAX(amount) FILTER (WHERE rang = 1)                       AS montant_dernier_paiement,
        COALESCE(SUM(amount) FILTER (WHERE payment_date >= CURRENT_DATE - 30), 0)
                                                                  AS paye_30_derniers_jours
    FROM paiements
    GROUP BY numero_contrat
),
base AS (
    SELECT
        uc.*,
        uc.contract_number::text                                  AS numero_contrat,
        uc.registration_date::date                                AS date_activation,
        uc.next_status_update::date                               AS prochaine_echeance,
        COALESCE(uc.consecutive_locked_days, 0)                   AS jours_retard,
        CURRENT_DATE - uc.registration_date::date                 AS age_jours,
        LEAST(
            uc.total_contract_value,
            uc.upfront_payment
              + GREATEST((CURRENT_DATE - uc.registration_date::date) - 30, 0)
                * (uc.monthly_payment / 30.0)
        )                                                         AS attendu_a_date
    FROM gold.unified_contracts uc
    WHERE uc.categorie IN ('upya_tevia', 'surge_tevia', 'upya_greeno')
      AND uc.deal_type = 'PAYG'
      AND uc.contract_status IN ('ENABLED', 'LOCKED')
      AND uc.registration_date IS NOT NULL
),
telephones AS (
    -- Partie entière seulement (au cas où la colonne serait flottante),
    -- chiffres seuls ; le 0 initial est restauré dans le SELECT final
    SELECT
        numero_contrat,
        NULLIF(regexp_replace(split_part(phone_number::text,   '.', 1), '\D', '', 'g'), '') AS tel1,
        NULLIF(regexp_replace(split_part(phone_number_2::text, '.', 1), '\D', '', 'g'), '') AS tel2
    FROM base
)
SELECT
    -- Identité du contrat
    b.numero_contrat,
    LOWER(b.entite)                                               AS entite,
    b.source,
    b.categorie,
    b.client_number                                               AS numero_client,
    b.customer_name                                               AS nom_client,
    CASE WHEN length(tp.tel1) = 9 THEN '0' || tp.tel1 ELSE tp.tel1 END AS telephone_1,
    CASE WHEN length(tp.tel2) = 9 THEN '0' || tp.tel2 ELSE tp.tel2 END AS telephone_2,
    b.agent_number                                                AS code_agent,
    b.agent_name                                                  AS nom_agent,
    b.product_name                                                AS produit,
    b.asset_number::text                                          AS numero_kit,

    -- Localisation : région seule ("Région nawa" → "NAWA")
    -- (préfixe retiré AVANT UPPER : en locale C, UPPER ne majuscule pas é)
    NULLIF(UPPER(regexp_replace(TRIM(b.region), '^r(é|É|e)gion\s+', '', 'i')), '')
                                                                  AS region,

    -- Dates et échéances
    b.paid_date::date                                             AS date_paiement_acompte,
    b.date_activation,
    b.age_jours,
    FLOOR(b.age_jours / 30.0)::int                                AS mois_ecoules,
    b.date_activation + 30                                        AS premiere_echeance,
    b.prochaine_echeance,
    b.last_status_update::date                                    AS derniere_maj_statut,
    CASE WHEN b.contract_status = 'ENABLED'
         THEN GREATEST(b.prochaine_echeance - CURRENT_DATE, 0)
    END                                                           AS jours_credit_restants,
    (b.contract_status = 'ENABLED'
     AND b.prochaine_echeance - CURRENT_DATE BETWEEN 0 AND 3)     AS expire_sous_3_jours,

    -- Statut et retard
    b.contract_status                                             AS statut_contrat,
    b.jours_retard,
    CASE
        WHEN b.jours_retard = 0               THEN 0
        WHEN b.jours_retard <= 30             THEN 1
        WHEN b.jours_retard <= 60             THEN 2
        WHEN b.jours_retard <= 90             THEN 3
        WHEN b.jours_retard <= 120            THEN 4
        WHEN b.jours_retard <= 180            THEN 5
        ELSE 6
    END                                                           AS tranche_ordre,
    CASE
        WHEN b.jours_retard = 0               THEN 'À jour'
        WHEN b.jours_retard <= 30             THEN '1-30 j'
        WHEN b.jours_retard <= 60             THEN '31-60 j'
        WHEN b.jours_retard <= 90             THEN '61-90 j'
        WHEN b.jours_retard <= 120            THEN '91-120 j'
        WHEN b.jours_retard <= 180            THEN '121-180 j'
        ELSE '180 j et plus'
    END                                                           AS tranche_retard,
    (b.jours_retard > 120)                                        AS perte_seuil_efa,
    (b.jours_retard >= 180)                                       AS perte_seuil_credit,
    (b.consecutive_locked_days IS NULL)                           AS jours_retard_inconnu,

    -- Montants (XOF)
    b.total_contract_value                                        AS valeur_contrat,
    b.upfront_payment                                             AS acompte,
    b.monthly_payment                                             AS mensualite,
    ROUND(b.monthly_payment / 30.0)                               AS tarif_journalier,
    b.total_paid                                                  AS total_paye,
    b.remaining_debt                                              AS reste_a_payer,
    ROUND(100.0 * b.total_paid / NULLIF(b.total_contract_value, 0), 1)
                                                                  AS pct_rembourse,
    ROUND(GREATEST(COALESCE(b.total_paid, 0) - COALESCE(b.upfront_payment, 0), 0)
          / NULLIF(b.monthly_payment, 0), 2)                      AS nb_mois_payes,
    CEIL(b.remaining_debt / NULLIF(b.monthly_payment, 0))::int   AS mensualites_restantes,
    ROUND(b.attendu_a_date)                                       AS attendu_a_date,
    ROUND(GREATEST(b.attendu_a_date - COALESCE(b.total_paid, 0), 0))
                                                                  AS arriere,

    -- Paiements
    sp.date_dernier_paiement,
    sp.montant_dernier_paiement,
    CURRENT_DATE - sp.date_dernier_paiement                       AS jours_depuis_dernier_paiement,
    COALESCE(sp.nb_paiements, 0)                                  AS nb_paiements,
    COALESCE(sp.paye_30_derniers_jours, 0)                        AS paye_30_derniers_jours,

    -- Fraîcheur
    b.computed_at                                                 AS source_calculee_le,
    now()                                                         AS rafraichi_le
FROM base b
JOIN telephones tp              ON tp.numero_contrat = b.numero_contrat
LEFT JOIN synthese_paiements sp ON sp.numero_contrat = b.numero_contrat;

-- Index unique : clé AppSheet + condition du REFRESH ... CONCURRENTLY
CREATE UNIQUE INDEX idx_rec_mv_contrats_pk     ON recouvrement.mv_contrats (numero_contrat);
CREATE INDEX        idx_rec_mv_contrats_entite ON recouvrement.mv_contrats (entite);
CREATE INDEX        idx_rec_mv_contrats_agent  ON recouvrement.mv_contrats (code_agent);


-- ---------------------------------------------------------------------------
-- 3. Vues lues par AppSheet
-- ---------------------------------------------------------------------------
CREATE VIEW recouvrement.contrats_tevia AS
SELECT * FROM recouvrement.mv_contrats WHERE entite = 'tevia';

CREATE VIEW recouvrement.contrats_greeno AS
SELECT * FROM recouvrement.mv_contrats WHERE entite = 'greeno';


-- ---------------------------------------------------------------------------
-- 4. Rafraîchissement
--    CONCURRENTLY : AppSheet continue de lire l'ancienne version pendant le
--    calcul. À appeler en fin de pipeline, après la mise à jour de
--    gold.unified_contracts :
--      SELECT recouvrement.rafraichir();
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recouvrement.rafraichir()
RETURNS void
LANGUAGE sql
AS $$
    REFRESH MATERIALIZED VIEW CONCURRENTLY recouvrement.mv_contrats;
$$;


-- ---------------------------------------------------------------------------
-- 5. Droits pour le rôle AppSheet (remplacer <role_appsheet>)
-- ---------------------------------------------------------------------------
-- GRANT USAGE  ON SCHEMA recouvrement TO <role_appsheet>;
-- GRANT SELECT ON recouvrement.contrats_tevia, recouvrement.contrats_greeno
--     TO <role_appsheet>;


-- ---------------------------------------------------------------------------
-- 6. Contrôles
-- ---------------------------------------------------------------------------
-- a. Volumes et encours par catégorie : doivent égaler la source
-- SELECT categorie, COUNT(*) AS nb, SUM(reste_a_payer) AS encours
-- FROM recouvrement.mv_contrats GROUP BY 1 ORDER BY 1;
--
-- b. prochaine_echeance cohérente avec le crédit acheté (UPYA) : la grande
--    majorité des écarts doit valoir 0
-- SELECT ROUND(prochaine_echeance - premiere_echeance - nb_mois_payes * 30) AS ecart_jours,
--        COUNT(*)
-- FROM recouvrement.contrats_tevia
-- WHERE source = 'upya'
-- GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
--
-- c. Répartition par tranche
-- SELECT entite, tranche_ordre, tranche_retard, COUNT(*) AS nb,
--        SUM(reste_a_payer) AS encours, SUM(arriere) AS arriere
-- FROM recouvrement.mv_contrats GROUP BY 1, 2, 3 ORDER BY 1, 2;
--
-- d. Téléphones restés hors format (doit être marginal)
-- SELECT COUNT(*) FROM recouvrement.mv_contrats
-- WHERE telephone_1 IS NOT NULL AND length(telephone_1) <> 10;


-- ---------------------------------------------------------------------------
-- 7. Correspondance des colonnes (gold.unified_contracts → recouvrement)
-- ---------------------------------------------------------------------------
-- contract_number          numero_contrat
-- client_number            numero_client
-- customer_name            nom_client
-- phone_number(_2)         telephone_1, telephone_2 (0 initial restauré)
-- agent_number, agent_name code_agent, nom_agent
-- product_name             produit
-- asset_number             numero_kit
-- paid_date                date_paiement_acompte
-- registration_date        date_activation
-- next_status_update       prochaine_echeance
-- last_status_update       derniere_maj_statut
-- contract_status          statut_contrat (valeurs inchangées : ENABLED, LOCKED)
-- consecutive_locked_days  jours_retard
-- total_contract_value     valeur_contrat
-- upfront_payment          acompte
-- monthly_payment          mensualite
-- total_paid               total_paye
-- remaining_debt           reste_a_payer
-- computed_at              source_calculee_le
-- Inchangés : entite, source, categorie, region
-- Non reprises : sub_prefecture, village, latitude, longitude