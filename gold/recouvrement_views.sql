-- delta/recouvrement-views.sql
-- Couche de service de l'application de recouvrement (AppSheet)
-- v4.1, 14/10/2026
--
-- Changement v4.1 : contrats_tevia liste ses colonnes explicitement et n'expose plus
--   les trois colonnes propres à GREENO (reference_greeno, retard_debut_mois_greeno,
--   source_premiere_echeance). contrats_greeno garde toutes les colonnes.
--
-- Changement v4 : contrats GREENO.
--   * Nouvelle vue recouvrement.contrats_greeno (filtre entite = 'greeno').
--   * premiere_echeance GREENO : date installment_date de greenodb
--     (silver.greeno_client_contracts_greeno) quand le kit y figure, sinon règle du
--     jour d'installation (1-5 → 5 M+1, 6-15 → 15 M+1, 16-25 → 25 M+1,
--     26-31 → 5 M+2). Règle vérifiée sur 50 contrats greenodb : 49 conformes,
--     1 exception (installé le 26/03, P1 au 25/04) : greenodb prime donc.
--   * Jointure greenodb ↔ unified_contracts par numéro de kit réduit à ses
--     chiffres (certains numéros de série finissent par "A").
--   * Nouvelles colonnes : source_premiere_echeance (greenodb / regle_greeno /
--     regle_tevia), reference_greeno (account_ref), retard_debut_mois_greeno.
--
-- Changement v3.2 : remise à zéro complète du schéma en tête de fichier (tout
--   objet présent est supprimé, quel que soit l'état laissé par les essais),
--   entite nettoyée des espaces (LOWER(TRIM(...))), et contrôle final exécuté
--   en fin de fichier (dernier résultat affiché par pgAdmin).
--
-- Changement v3.1 : nouvelle colonne jours_manques_cumules.
--   Nombre total de jours sans crédit depuis l'activation, coupure en cours
--   comprise (jours_retard ne compte que la coupure en cours).
--   Le champ UPYA accumulatedLateDays n'est PAS utilisé : vérifié sur l'export
--   du 29/09/2026, il vaut 0 pour tous les contrats LOCKED et, pour les contrats
--   ENABLED récents, il égale le délai acompte → installation dans 88 % des cas.
--   Il compte donc l'attente d'installation et ignore la coupure en cours.
--   Limites du calcul DELTA : suppose 1 mensualité = 30 jours de crédit.
--   * Contrats UPYA anciens qui ont reçu plus de jours que le cash ne l'explique
--     (jours offerts, changement de tarif) : valeur surestimée.
--   * SURGE : total_paid inclut les pénalités de retard, valeur sous-estimée.
--
-- Changement v3 : la vue matérialisée est remplacée par une table.
--   Constat du 13/10/2026 : AppSheet ne lit pas les vues construites sur la vue
--   matérialisée (contrats_tevia, test_rec_contrats_tevia), alors qu'il lit une
--   vue simple branchée directement sur gold (vw_contrats). Une vue simple seule
--   recalculerait toute la chaîne à chaque synchronisation : c'est la lenteur
--   qu'on cherchait à supprimer. Une table ordinaire, remplie par la fonction de
--   rafraîchissement, garde les deux avantages : stockée et indexée comme la vue
--   matérialisée, et lisible par AppSheet comme n'importe quelle table.
--
--   Corrections par rapport au vw_contrats écrit le 13/10 :
--   * entite : LOWER(b.source) donnait 'upya'/'surge' au lieu de 'tevia'/'greeno'.
--     Corrigé en LOWER(b.entite).
--   * Tranches : la tranche "151-180 j" ne contenait que les contrats à 151 jours
--     exactement (condition <= 151) ; 152 à 179 tombaient dans "180 j et plus".
--     Corrigé, et la limite des 180 jours est alignée sur perte_seuil_credit.
--   * Conservé : le filtre asset_number IS NOT NULL ajouté le 13/10.
--
-- Architecture :
--   gold.unified_contracts ───┐
--                             ├─> recouvrement.vw_contrats   (vue simple : la logique,
--   gold.unified_transactions ┘     source de vérité des calculs)
--                                         │
--                         recouvrement.rafraichir()  copie le résultat
--                                         ▼
--                              recouvrement.contrats      (table : stockée, indexée,
--                                         │                 lue par AppSheet)
--                                         ▼
--                              recouvrement.contrats_tevia (vue simple : WHERE entite)
--
-- Périmètre :
--   PAYG, activé, avec un kit (asset_number), statut ENABLED ou LOCKED.
--   Catégories : upya_tevia, surge_tevia (portefeuille TEVIA), upya_greeno.
--
-- Règles de calcul : inchangées depuis la v2.1 (voir les commentaires du SELECT).
--   prochaine_echeance = next_status_update (vérifié : 94 % des contrats UPYA
--   récents égalent activation + 30 j + jours achetés) ; premiere_echeance =
--   date_activation + 30 j ; mois_ecoules = FLOOR(age_jours / 30) ;
--   nb_mois_payes = (total_paye - acompte) / mensualite.
--
-- Points ouverts :
--   * GREENO : arriere, attendu_a_date, nb_mois_payes et jours_manques_cumules
--     suivent encore la logique TEVIA (30 jours après activation). À aligner
--     sur premiere_echeance si l'équipe crédit le valide.
--   * Saisies de l'app (appels, promesses) : à stocker dans une table dédiée.


-- ---------------------------------------------------------------------------
-- 1. Remise à zéro : supprime TOUT ce que contient le schéma recouvrement
--    (vues, vues matérialisées, tables), quel que soit son état actuel.
--    Vues d'abord, puis vues matérialisées, puis tables. CASCADE emporte aussi
--    les objets d'autres schémas qui en dépendent (ex. une vue de test dans gold).
--    La fonction rafraichir() n'est pas une table : elle est recréée plus bas.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS recouvrement;

DO $$
DECLARE o record;
BEGIN
  FOR o IN
    SELECT c.relname, c.relkind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'recouvrement'
      AND c.relkind IN ('v', 'm', 'r')
    ORDER BY CASE c.relkind WHEN 'v' THEN 1 WHEN 'm' THEN 2 ELSE 3 END
  LOOP
    EXECUTE format('DROP %s IF EXISTS recouvrement.%I CASCADE',
                   CASE o.relkind WHEN 'v' THEN 'VIEW'
                                  WHEN 'm' THEN 'MATERIALIZED VIEW'
                                  ELSE 'TABLE' END,
                   o.relname);
    RAISE NOTICE 'supprimé : %', o.relname;
  END LOOP;
END $$;

DROP VIEW IF EXISTS gold.test_rec_contrats_tevia;


-- ---------------------------------------------------------------------------
-- 2. Vue de calcul : toute la logique métier, une ligne par contrat
-- ---------------------------------------------------------------------------
CREATE VIEW recouvrement.vw_contrats AS
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
greeno_ext AS (
    -- Contrats GREENO issus de greenodb : première échéance de référence.
    -- Clé de jointure = numéro de série réduit à ses chiffres
    -- ("868064077655410A" → "868064077655410"). Si un kit apparaît plusieurs
    -- fois (plusieurs snapshots), on garde la photo la plus récente.
    SELECT DISTINCT ON (cle_kit)
        cle_kit,
        account_ref,
        installment_date,
        retard_debut_mois
    FROM (
        SELECT
            regexp_replace(serial_number, '\D', '', 'g')          AS cle_kit,
            NULLIF(TRIM(account_ref), '')                         AS account_ref,
            installment_date::date                                AS installment_date,
            NULLIF(TRIM(retard_debut_mois::text), '')::int        AS retard_debut_mois,
            date_snapshot,
            loaded_at
        FROM silver.greeno_client_contracts_greeno
        WHERE serial_number IS NOT NULL
    ) g
    WHERE cle_kit <> ''
    ORDER BY cle_kit, date_snapshot DESC, loaded_at DESC
),
base AS (
    SELECT
        uc.*,
        uc.contract_number::text                                  AS numero_contrat,
        uc.registration_date::date                                AS date_activation,
        uc.next_status_update::date                               AS prochaine_echeance,
        ge.account_ref                                            AS reference_greeno,
        ge.retard_debut_mois                                      AS retard_debut_mois_greeno,
        -- Première échéance (P1)
        --   TEVIA  : activation + 30 jours
        --   GREENO : date greenodb si le kit y figure (elle prime : elle porte
        --            les exceptions), sinon règle du jour d'installation :
        --              1-5   → le 5  du mois suivant
        --              6-15  → le 15 du mois suivant
        --              16-25 → le 25 du mois suivant
        --              26-31 → le 5  du mois M+2
        CASE
            WHEN uc.categorie <> 'upya_greeno'
                THEN uc.registration_date::date + 30
            WHEN ge.installment_date IS NOT NULL
                THEN ge.installment_date
            ELSE (date_trunc('month', uc.registration_date::date)
                  + CASE
                        WHEN EXTRACT(DAY FROM uc.registration_date) <= 5  THEN INTERVAL '1 month 4 days'
                        WHEN EXTRACT(DAY FROM uc.registration_date) <= 15 THEN INTERVAL '1 month 14 days'
                        WHEN EXTRACT(DAY FROM uc.registration_date) <= 25 THEN INTERVAL '1 month 24 days'
                        ELSE INTERVAL '2 months 4 days'
                    END)::date
        END                                                       AS premiere_echeance,
        CASE
            WHEN uc.categorie <> 'upya_greeno'   THEN 'regle_tevia'
            WHEN ge.installment_date IS NOT NULL THEN 'greenodb'
            ELSE 'regle_greeno'
        END                                                       AS source_premiere_echeance,
        COALESCE(uc.consecutive_locked_days, 0)                   AS jours_retard,
        CURRENT_DATE - uc.registration_date::date                 AS age_jours,
        LEAST(
            uc.total_contract_value,
            uc.upfront_payment
              + GREATEST((CURRENT_DATE - uc.registration_date::date) - 30, 0)
                * (uc.monthly_payment / 30.0)
        )                                                         AS attendu_a_date
    FROM gold.unified_contracts uc
    LEFT JOIN greeno_ext ge
           ON uc.categorie = 'upya_greeno'
          AND ge.cle_kit = regexp_replace(split_part(uc.asset_number::text, '.', 1), '\D', '', 'g')
    WHERE uc.categorie IN ('upya_tevia', 'surge_tevia', 'upya_greeno')
      AND uc.deal_type = 'PAYG'
      AND uc.contract_status IN ('ENABLED', 'LOCKED')
      AND uc.registration_date IS NOT NULL
      AND uc.asset_number IS NOT NULL
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
    LOWER(TRIM(b.entite))                                         AS entite,   -- tevia / greeno (jamais source), sans espaces parasites
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
    b.reference_greeno,                                           -- account_ref greenodb (NULL hors GREENO)
    b.retard_debut_mois_greeno,                                   -- retard en début de mois selon greenodb

    -- Localisation : région seule ("Région nawa" → "NAWA")
    -- (préfixe retiré AVANT UPPER : en locale C, UPPER ne majuscule pas é)
    NULLIF(UPPER(regexp_replace(TRIM(b.region), '^r(é|É|e)gion\s+', '', 'i')), '')
                                                                  AS region,

    -- Dates et échéances
    b.paid_date::date                                             AS date_paiement_acompte,
    b.date_activation,
    b.age_jours,
    FLOOR(b.age_jours / 30.0)::int                                AS mois_ecoules,
    b.premiere_echeance,
    b.source_premiere_echeance,
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
        WHEN b.jours_retard <= 150            THEN 5
        WHEN b.jours_retard <  180            THEN 6
        ELSE 7
    END                                                           AS tranche_ordre,
    CASE
        WHEN b.jours_retard = 0               THEN 'À jour'
        WHEN b.jours_retard <= 30             THEN '1-30 j'
        WHEN b.jours_retard <= 60             THEN '31-60 j'
        WHEN b.jours_retard <= 90             THEN '61-90 j'
        WHEN b.jours_retard <= 120            THEN '91-120 j'
        WHEN b.jours_retard <= 150            THEN '121-150 j'
        WHEN b.jours_retard <  180            THEN '151-179 j'
        ELSE '180 j et plus'                       -- même limite que perte_seuil_credit
    END                                                           AS tranche_retard,
    (b.jours_retard > 120)                                        AS perte_seuil_efa,
    (b.jours_retard >= 180)                                       AS perte_seuil_credit,
    (b.consecutive_locked_days IS NULL)                           AS jours_retard_inconnu,
    -- Jours sans crédit depuis l'activation, coupure en cours comprise.
    -- Jours écoulés - jours déjà consommés, où jours consommés = jours achetés
    -- (30 j d'acompte + paiements nets / tarif journalier) - crédit restant.
    -- Plafonné à age_jours, puis jamais inférieur à jours_retard : la coupure
    -- en cours (donnée UPYA) prime, même si les dates source sont incohérentes.
    GREATEST(
        LEAST(
            b.age_jours,
            ROUND(
                b.age_jours
                - (30 + GREATEST(COALESCE(b.total_paid, 0) - COALESCE(b.upfront_payment, 0), 0)
                        * 30.0 / NULLIF(b.monthly_payment, 0))
                + CASE WHEN b.contract_status = 'ENABLED'
                       THEN GREATEST(b.prochaine_echeance - CURRENT_DATE, 0) ELSE 0 END
            )::int
        ),
        b.jours_retard
    )                                                             AS jours_manques_cumules,

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

    -- Fraîcheur : dans la table, now() fige l'heure du rafraîchissement
    b.computed_at                                                 AS source_calculee_le,
    now()                                                         AS rafraichi_le
FROM base b
JOIN telephones tp              ON tp.numero_contrat = b.numero_contrat
LEFT JOIN synthese_paiements sp ON sp.numero_contrat = b.numero_contrat;


-- ---------------------------------------------------------------------------
-- 3. Table de service : copie stockée de vw_contrats, lue par AppSheet
--    Mêmes colonnes et mêmes types que la vue, créés automatiquement.
-- ---------------------------------------------------------------------------
CREATE TABLE recouvrement.contrats AS
SELECT * FROM recouvrement.vw_contrats;

-- Clé primaire : AppSheet la détecte comme colonne clé
ALTER TABLE recouvrement.contrats ADD PRIMARY KEY (numero_contrat);
CREATE INDEX idx_rec_contrats_entite ON recouvrement.contrats (entite);
CREATE INDEX idx_rec_contrats_agent  ON recouvrement.contrats (code_agent);


-- ---------------------------------------------------------------------------
-- 4. Vue lue par l'app TEVIA (un simple filtre sur la table)
-- ---------------------------------------------------------------------------
CREATE VIEW recouvrement.contrats_tevia AS
-- Colonnes listées explicitement : les colonnes propres à GREENO
-- (reference_greeno, retard_debut_mois_greeno, source_premiere_echeance) sont exclues.
SELECT
    numero_contrat, entite, source, categorie,
    numero_client, nom_client, telephone_1, telephone_2,
    code_agent, nom_agent, produit, numero_kit,
    region, date_paiement_acompte, date_activation, age_jours,
    mois_ecoules, premiere_echeance, prochaine_echeance, derniere_maj_statut,
    jours_credit_restants, expire_sous_3_jours, statut_contrat, jours_retard,
    tranche_ordre, tranche_retard, perte_seuil_efa, perte_seuil_credit,
    jours_retard_inconnu, jours_manques_cumules, valeur_contrat, acompte,
    mensualite, tarif_journalier, total_paye, reste_a_payer,
    pct_rembourse, nb_mois_payes, mensualites_restantes, attendu_a_date,
    arriere, date_dernier_paiement, montant_dernier_paiement, jours_depuis_dernier_paiement,
    nb_paiements, paye_30_derniers_jours, source_calculee_le, rafraichi_le
FROM recouvrement.contrats
WHERE entite = 'tevia';

CREATE VIEW recouvrement.contrats_greeno AS
SELECT * FROM recouvrement.contrats WHERE entite = 'greeno';


-- ---------------------------------------------------------------------------
-- 5. Rafraîchissement
--    Même nom qu'avant : l'étape du workflow GitHub ne change pas.
--    DELETE puis INSERT dans une seule transaction (le corps d'une fonction
--    s'exécute d'un bloc) : pendant le recalcul, AppSheet continue de lire
--    l'ancienne version ; la nouvelle apparaît d'un coup à la fin.
--    Un TRUNCATE serait plus rapide mais bloquerait les lectures.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recouvrement.rafraichir()
RETURNS void
LANGUAGE sql
AS $$
    DELETE FROM recouvrement.contrats;
    INSERT INTO recouvrement.contrats SELECT * FROM recouvrement.vw_contrats;
$$;


-- ---------------------------------------------------------------------------
-- 6. Droits
--    Les privilèges par défaut du schéma couvrent déjà les objets créés par
--    postgres. GRANT explicite par sécurité.
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA recouvrement TO role_read, lucien;
GRANT SELECT ON recouvrement.contrats, recouvrement.contrats_tevia,
                recouvrement.contrats_greeno, recouvrement.vw_contrats
    TO role_read, lucien;


-- ---------------------------------------------------------------------------
-- 7. Contrôles
-- ---------------------------------------------------------------------------
-- a. La table égale la vue de calcul (les deux nombres doivent être identiques)
-- SELECT (SELECT COUNT(*) FROM recouvrement.contrats)   AS table_contrats,
--        (SELECT COUNT(*) FROM recouvrement.vw_contrats) AS vue_calcul;
--
-- b. Le split entité est bon (tevia et greeno, jamais upya/surge)
-- SELECT entite, categorie, COUNT(*) FROM recouvrement.contrats GROUP BY 1, 2 ORDER BY 1, 2;
--
-- c. Répartition par tranche, 151-179 doit maintenant être peuplée
-- SELECT tranche_ordre, tranche_retard, COUNT(*), MIN(jours_retard), MAX(jours_retard)
-- FROM recouvrement.contrats GROUP BY 1, 2 ORDER BY 1;
--
-- d. jours_manques_cumules : jamais sous jours_retard (incoherents doit valoir 0) ;
--    depasse_age compte les contrats dont la coupure en cours dépasse l'âge
--    depuis l'activation (dates source incohérentes, à signaler à l'équipe CRM)
-- SELECT COUNT(*) FILTER (WHERE jours_manques_cumules < jours_retard) AS incoherents,
--        COUNT(*) FILTER (WHERE jours_manques_cumules > age_jours)    AS depasse_age
-- FROM recouvrement.contrats;
-- SELECT categorie, statut_contrat,
--        ROUND(AVG(jours_retard))          AS retard_moyen,
--        ROUND(AVG(jours_manques_cumules)) AS manques_cumules_moyen,
--        MAX(jours_manques_cumules)        AS manques_cumules_max
-- FROM recouvrement.contrats GROUP BY 1, 2 ORDER BY 1, 2;
--
-- e. GREENO : rattachement à greenodb (attendu : ~2 078 'greenodb')
-- SELECT source_premiere_echeance, COUNT(*)
-- FROM recouvrement.contrats_greeno GROUP BY 1;
--    Kits greenodb absents des contrats GREENO (à investiguer s'il y en a)
-- SELECT COUNT(*) FROM silver.greeno_client_contracts_greeno g
-- WHERE NOT EXISTS (SELECT 1 FROM recouvrement.contrats_greeno c
--                   WHERE regexp_replace(c.numero_kit, '\D', '', 'g')
--                       = regexp_replace(g.serial_number, '\D', '', 'g'));
--    (comparer les deux numéros nettoyés : certains numero_kit gardent un suffixe,
--     ex. 868064077653886A ; vérifié le 14/10 : les 59 kits greenodb hors vue sont
--     46 contrats soldés ou repossédés et 13 faux écarts dus à ce suffixe)
--
-- f. Heure du dernier rafraîchissement
-- SELECT MAX(rafraichi_le) FROM recouvrement.contrats;
--
-- Si la structure de vw_contrats change (colonne ajoutée ou renommée) :
-- relancer tout ce fichier (la table est recréée à partir de la vue),
-- puis "Regenerate structure" dans AppSheet.


-- ---------------------------------------------------------------------------
-- 8. Contrôle final (dernier résultat affiché par pgAdmin)
--    vue_calcul = table_contrats ; vue_tevia > 0 ; lucien_lit_tevia = true
-- ---------------------------------------------------------------------------
SELECT (SELECT COUNT(*) FROM recouvrement.vw_contrats)    AS vue_calcul,
       (SELECT COUNT(*) FROM recouvrement.contrats)       AS table_contrats,
       (SELECT COUNT(*) FROM recouvrement.contrats_tevia) AS vue_tevia,
       (SELECT COUNT(*) FROM recouvrement.contrats_greeno) AS vue_greeno,
       (SELECT COUNT(*) FROM recouvrement.contrats_greeno
         WHERE source_premiere_echeance = 'greenodb')     AS greeno_rattaches_greenodb,
       has_table_privilege('lucien', 'recouvrement.contrats_tevia', 'SELECT') AS lucien_lit_tevia;