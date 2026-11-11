-- gold-unified-contracts-v17.sql  (04/11/2026, v17.1 ; v17.1.1 le 11/11/2026)
-- v17.1.1 : phone_number_2 = second mobile SURGE, sinon contact.secondaryMobile
--   de la fiche UPYA (silver.upya_clients.contact_json, generic_loader v2).
-- v17.1 : région et sous-préfecture des migrés reprises de SURGE quand UPYA
--   n'en a pas (rattachement au régional du comité : 76,7 % en v17).
-- gold.unified_contracts v16 → v17 : migration des clients SURGE dans UPYA
-- (effective le 1er novembre 2026).
--
-- Constat du 04/11 (delta/constat-migration-surge-2026-11-04.md) :
--   * les 69 574 contrats SURGE sont dans UPYA sous un numéro préfixé
--     (N + numéro SURGE pour NEoTCI, T + numéro SURGE pour TEVIA et ZECI) ;
--     gold les comptait deux fois (branche SURGE + branche UPYA) ;
--   * la branche UPYA les classait tous en upya_tevia, NEoTCI compris ;
--   * 5 307 contrats repris et 623 soldés dans SURGE sont actifs dans UPYA
--     (statut « Removed » et paid off non repris à l'import).
--
-- Règles v17 (validées par Tanguy le 04/11/2026)
--   * Une seule source : UPYA. La branche SURGE est retirée.
--   * 3 entités : greeno, tevia, neotci.
--   * 5 catégories :
--       upya_greeno  : entité UPYA GREENO
--       surge_neotci : préfixe N, ou entité UPYA NEOT sans préfixe T
--       surge_tevia  : préfixe T, catégorie SURGE d'origine surge_tevia
--       surge_zeci   : préfixe T, catégorie SURGE d'origine surge_zeci
--       upya_tevia   : tout le reste (entité TEVIA, « Ivory Cost » ou vide)
--     La catégorie SURGE d'origine est recalculée comme avant, à partir de
--     silver.surge_contracts (données gelées au 31/10) retrouvé par le numéro
--     d'origine : liste NEoTCI, sinon paid_at ≥ 01/04/2024 → surge_tevia,
--     sinon surge_zeci.
--   * Statut : tant qu'UPYA n'a pas corrigé, un contrat migré actif dans UPYA
--     (ENABLED, LOCKED) mais repris ou soldé dans SURGE garde le statut SURGE,
--     avec sa date de reprise ou de solde. Colonne statut_corrige_surge = true.
--   * Date d'activation des migrés : premier déploiement du kit dans UPYA,
--     sinon date de signature UPYA (date d'activation SURGE migrée).
--   * Second téléphone des migrés : silver.surge_legacy_contacts.
--
-- Nouvelles colonnes, ajoutées en fin de vue (CREATE OR REPLACE suffit) :
--   numero_origine       numéro SURGE sans préfixe (NULL hors migrés)
--   origine              'surge' pour les migrés, 'upya' sinon
--   statut_corrige_surge true si le statut vient de SURGE et non d'UPYA
-- Les colonnes existantes gardent leur nom, leur type et leur ordre.
-- source vaut désormais 'upya' partout : les règles UPYA (jours de retard
-- depuis next_status_update) s'appliquent aux migrés dans le recouvrement.
--
-- Exécution : tout le fichier d'un bloc, un seul onglet pgAdmin. Puis
-- SELECT * FROM recouvrement.rafraichir(); et les contrôles en fin de fichier.
-- Retour arrière : relancer delta/gold-unified-contracts-v16.sql (les trois
-- nouvelles colonnes doivent alors être retirées : DROP VIEW … CASCADE n'est
-- pas nécessaire tant qu'aucun objet ne les lit).
-- ============================================================================

SET lock_timeout = '60s';

-- Le calcul est posé dans gold.unified_contracts_calc ; gold.unified_contracts
-- le relit ensuite en gardant exactement les types de ses colonnes actuelles
-- (bloc DO plus bas). Sans cela, un type de date différent de la v16 ferait
-- échouer CREATE OR REPLACE VIEW et obligerait à supprimer les vues qui en
-- dépendent.
CREATE OR REPLACE VIEW gold.unified_contracts_calc
 AS
 WITH neotci AS (
         SELECT DISTINCT surge_neotci_list.contract_number::text AS contract_number
           FROM silver.surge_neotci_list
        ), surge_ref AS (
         -- Données SURGE gelées : catégorie, statut et dates d'origine des migrés
         SELECT s.installation_id::text AS numero_origine,
                CASE
                    WHEN s.installation_id::text IN (SELECT contract_number FROM neotci) THEN 'surge_neotci'::text
                    WHEN s.paid_at >= '2024-04-01'::date THEN 'surge_tevia'::text
                    ELSE 'surge_zeci'::text
                END AS categorie_surge,
                CASE
                    WHEN sp.paid_off_date IS NOT NULL THEN 'PAID_OFF'::text
                    WHEN s.removed_at IS NOT NULL
                      OR upper(TRIM(BOTH FROM s.status)) = ANY (ARRAY['DISABLED'::text, 'REPOSSESSED'::text]) THEN 'REPOSSESSED'::text
                    ELSE NULL::text
                END AS statut_final_surge,
                NULLIF(TRIM(BOTH FROM s.region), '')      AS region_surge,
                NULLIF(TRIM(BOTH FROM s.ward), '')        AS ward_surge,
                sp.paid_off_date::timestamp with time zone AS paid_off_date_surge,
                s.removed_at::timestamp with time zone     AS repossession_date_surge
           FROM silver.surge_contracts s
             LEFT JOIN (SELECT contract_number::text AS contract_number, MAX(paid_off_date) AS paid_off_date
                          FROM silver.surge_paidoff GROUP BY 1) sp
                    ON sp.contract_number = s.installation_id::text
        ), surge_tel AS (
         SELECT DISTINCT ON (contract_number::text) contract_number::text AS numero_origine,
                snd_mobile
           FROM silver.surge_legacy_contacts
          ORDER BY contract_number::text
        ), upya_assets_latest AS (
         SELECT DISTINCT ON (upya_assets.contract_number) upya_assets.contract_number,
            upya_assets.payg_number,
            COALESCE(upya_assets.deploy_date, upya_assets.date_added) AS deploy_date,
            -- v16 : premier déploiement du contrat (kits remplacés compris)
            MIN(COALESCE(upya_assets.deploy_date, upya_assets.date_added))
                OVER (PARTITION BY upya_assets.contract_number) AS first_deploy_date,
            upya_assets.serial_number,
            upya_assets.status AS asset_status
           FROM silver.upya_assets
          WHERE upya_assets.contract_number IS NOT NULL AND upya_assets.status = 'DEPLOYED'::text
          ORDER BY upya_assets.contract_number, (COALESCE(upya_assets.deploy_date, upya_assets.date_added)) DESC NULLS LAST
        ), upya_c AS (
         SELECT c.*,
                CASE WHEN c.contract_number ~ '^[NT][0-9]+$'
                     THEN substring(c.contract_number FROM 2) END AS numero_origine
           FROM silver.upya_contracts c
          WHERE c.contract_number IS NOT NULL AND TRIM(BOTH FROM c.contract_number) <> ''::text AND c.onboarding_status IS NOT NULL
        ), upya AS (
         SELECT c.contract_number,
                cat.categorie,
                CASE cat.categorie
                    WHEN 'upya_greeno'  THEN 'greeno'::text
                    WHEN 'surge_neotci' THEN 'neotci'::text
                    ELSE 'tevia'::text
                END AS entite,
            'upya'::text AS source,
            c.client_number,
            c.customer_name,
            c.agent_number,
            c.agent_name,
            c.signing_date AS paid_date,
            COALESCE(a.first_deploy_date,
                     CASE WHEN c.numero_origine IS NOT NULL THEN c.signing_date END) AS registration_date,
            c.last_status_update,
            c.next_status_update,
            CASE WHEN corr.statut = 'PAID_OFF' THEN COALESCE(c.paid_off_date, r.paid_off_date_surge)
                 ELSE c.paid_off_date END AS paid_off_date,
            CASE WHEN corr.statut = 'REPOSSESSED' THEN COALESCE(c.repossession_date, r.repossession_date_surge)
                 ELSE c.repossession_date END AS repossession_date,
            COALESCE(a.payg_number, c.asset_number) AS asset_number,
            c.deal_type AS deal_type_raw,
            c.total_cost AS total_contract_value,
            c.upfront_payment,
            c.monthly_payment,
            c.total_paid,
            CASE WHEN corr.statut = 'PAID_OFF' THEN 0::numeric ELSE c.remaining_debt END AS remaining_debt,
            COALESCE(corr.statut, c.status) AS contract_status_raw,
            CASE WHEN corr.statut = 'PAID_OFF' THEN 'yes'::text ELSE c.paid_off_status END AS paid_off_raw,
            c.product_name,
            -- v17.1 : la base migrée n'a pas de localisation ; celle de SURGE est reprise
            COALESCE(NULLIF(TRIM(BOTH FROM c.region), ''), r.region_surge) AS region,
            COALESCE(NULLIF(TRIM(BOTH FROM c.sub_prefecture), ''), r.ward_surge) AS sub_prefecture,
            c.village,
            c.latitude,
            c.longitude,
            cl.mobile AS phone_number,
            -- v17.1.1 (11/11/2026) : second mobile de la fiche UPYA (contact.secondaryMobile,
            -- lu par generic_loader v2) quand SURGE n'en donne pas
            COALESCE(NULLIF(TRIM(st.snd_mobile::text), ''),
                     NULLIF(TRIM(cl.contact_json ->> 'secondaryMobile'), '')) AS phone_number_2,
            c.numero_origine,
            CASE WHEN c.numero_origine IS NOT NULL THEN 'surge'::text ELSE 'upya'::text END AS origine,
            (corr.statut IS NOT NULL) AS statut_corrige_surge
           FROM upya_c c
             LEFT JOIN upya_assets_latest a ON a.contract_number = c.contract_number
             LEFT JOIN silver.upya_clients cl ON cl.client_number = c.client_number
             LEFT JOIN surge_ref r ON r.numero_origine = c.numero_origine
             LEFT JOIN surge_tel st ON st.numero_origine = c.numero_origine
             CROSS JOIN LATERAL (
                SELECT CASE
                    WHEN upper(TRIM(BOTH FROM c.entity_name)) = 'GREENO'          THEN 'upya_greeno'::text
                    WHEN c.contract_number ~ '^N[0-9]'                            THEN 'surge_neotci'::text
                    WHEN c.contract_number ~ '^T[0-9]' AND r.categorie_surge = 'surge_zeci' THEN 'surge_zeci'::text
                    WHEN c.contract_number ~ '^T[0-9]'                            THEN 'surge_tevia'::text
                    WHEN upper(TRIM(BOTH FROM c.entity_name)) = 'NEOT'            THEN 'surge_neotci'::text
                    ELSE 'upya_tevia'::text
                END AS categorie
             ) cat
             CROSS JOIN LATERAL (
                -- Statut SURGE retenu quand UPYA présente actif un contrat repris ou soldé
                SELECT CASE
                    WHEN c.numero_origine IS NOT NULL
                     AND upper(TRIM(BOTH FROM c.status)) = ANY (ARRAY['ENABLED'::text, 'LOCKED'::text, 'ACTIVE'::text])
                    THEN r.statut_final_surge
                END AS statut
             ) corr
        ), normalized AS (
         SELECT u.*,
                CASE
                    WHEN upper(TRIM(BOTH FROM u.contract_status_raw)) = ANY (ARRAY['ACTIVE'::text, 'ENABLED'::text, 'AWAITING REMOVAL'::text]) THEN 'ENABLED'::text
                    WHEN upper(TRIM(BOTH FROM u.contract_status_raw)) = ANY (ARRAY['DISABLED'::text, 'REPOSSESSED'::text]) THEN 'REPOSSESSED'::text
                    WHEN upper(TRIM(BOTH FROM u.contract_status_raw)) = 'LOCKED'::text THEN 'LOCKED'::text
                    WHEN upper(TRIM(BOTH FROM u.contract_status_raw)) = ANY (ARRAY['PAID_OFF'::text, 'PAIDOFF'::text]) THEN 'PAID_OFF'::text
                    WHEN upper(TRIM(BOTH FROM u.contract_status_raw)) = 'CANCELLED'::text THEN 'CANCELLED'::text
                    ELSE upper(TRIM(BOTH FROM u.contract_status_raw))
                END AS contract_status,
                CASE
                    WHEN lower(TRIM(BOTH FROM u.paid_off_raw)) = ANY (ARRAY['yes'::text, 'true'::text, '1'::text]) THEN 'true'::text
                    ELSE 'false'::text
                END AS paid_off,
                CASE
                    WHEN upper(TRIM(BOTH FROM u.deal_type_raw)) = ANY (ARRAY['NO'::text, 'PAYG'::text, 'INSTALMENTS'::text]) THEN 'PAYG'::text
                    WHEN upper(TRIM(BOTH FROM u.deal_type_raw)) = ANY (ARRAY['YES'::text, 'FULL'::text]) THEN 'FULL'::text
                    ELSE 'PAYG'::text
                END AS deal_type
           FROM upya u
        )
 SELECT contract_number, entite, source, categorie, client_number, customer_name,
    agent_number, agent_name, paid_date, registration_date, last_status_update,
    next_status_update, paid_off_date, repossession_date, product_name, asset_number,
    deal_type, total_contract_value, upfront_payment, monthly_payment, total_paid,
    remaining_debt, contract_status, paid_off, region, sub_prefecture, village,
    latitude, longitude,
        CASE
            WHEN deal_type = 'FULL'::text THEN NULL::integer
            WHEN contract_status = 'REPOSSESSED'::text THEN NULL::integer
            WHEN contract_status = 'CANCELLED'::text THEN NULL::integer
            WHEN contract_status = 'PAID_OFF'::text THEN NULL::integer
            WHEN paid_off = 'true'::text THEN NULL::integer
            WHEN next_status_update IS NOT NULL THEN GREATEST(0, floor(EXTRACT(epoch FROM CURRENT_TIMESTAMP - (next_status_update AT TIME ZONE 'Africa/Abidjan'::text)::timestamp with time zone) / 86400::numeric)::integer)
            ELSE NULL::integer
        END AS consecutive_locked_days,
    ( SELECT max(run_log.run_at) AS max
           FROM bronze_meta.run_log
          WHERE run_log.status = 'success'::text AND (run_log.entity = ANY (ARRAY['contracts'::text, 'clients'::text, 'assets'::text, 'payments'::text]))) AS computed_at,
    phone_number,
    phone_number_2,
    numero_origine,
    origine,
    statut_corrige_surge
   FROM normalized;

-- gold.unified_contracts : mêmes colonnes, mêmes types qu'avant, plus les trois
-- nouvelles colonnes en fin de vue
DO $$
DECLARE
    cols text;
BEGIN
    SELECT string_agg(format('c.%I::%s AS %I', a.attname,
                             format_type(a.atttypid, a.atttypmod), a.attname),
                      ', ' ORDER BY a.attnum)
      INTO cols
      FROM pg_attribute a
     WHERE a.attrelid = 'gold.unified_contracts'::regclass
       AND a.attnum > 0 AND NOT a.attisdropped
       AND a.attname NOT IN ('numero_origine', 'origine', 'statut_corrige_surge');

    EXECUTE 'CREATE OR REPLACE VIEW gold.unified_contracts AS SELECT ' || cols
         || ', c.numero_origine, c.origine, c.statut_corrige_surge'
         || ' FROM gold.unified_contracts_calc c';
END $$;

ALTER TABLE gold.unified_contracts OWNER TO postgres;
GRANT SELECT ON gold.unified_contracts_calc TO aboubacar, data_analyst, herve, lucien, role_read;

GRANT SELECT ON TABLE gold.unified_contracts TO aboubacar, data_analyst, herve, lucien, role_read;
GRANT ALL ON TABLE gold.unified_contracts TO postgres;


-- ----------------------------------------------------------------------------
-- Liste à envoyer à UPYA : contrats migrés dont le statut UPYA contredit SURGE
-- (à exporter en CSV ; elle se vide à mesure qu'UPYA corrige)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW gold.v_migration_statuts_a_corriger AS
SELECT u.contract_number                                 AS numero_contrat_upya,
       u.numero_origine                                  AS numero_surge,
       u.categorie,
       c.status                                          AS statut_upya,
       u.contract_status                                 AS statut_a_appliquer,
       CASE u.contract_status
            WHEN 'REPOSSESSED' THEN u.repossession_date::date
            WHEN 'PAID_OFF'    THEN u.paid_off_date::date
       END                                               AS date_a_appliquer,
       u.customer_name,
       u.asset_number
FROM gold.unified_contracts u
JOIN silver.upya_contracts c ON c.contract_number = u.contract_number
WHERE u.statut_corrige_surge;

GRANT SELECT ON gold.v_migration_statuts_a_corriger TO role_read, lucien;


-- ----------------------------------------------------------------------------
-- Contrôles (lancer chaque requête seule après l'exécution)
-- ----------------------------------------------------------------------------
-- 1. Plus de doublons : aucun contrat source = 'surge', chaque numéro une fois
-- SELECT source, COUNT(*), COUNT(DISTINCT contract_number) FROM gold.unified_contracts GROUP BY 1;
--
-- 2. Répartition attendue (04/11) : surge_neotci ≈ 51 269, surge_tevia ≈ 6 193,
--    surge_zeci ≈ 12 101, upya_greeno ≈ 3 270
-- SELECT entite, categorie, origine, contract_status, COUNT(*)
-- FROM gold.unified_contracts GROUP BY 1, 2, 3, 4 ORDER BY 1, 2, 3, 4;
--
-- 3. Statuts repris de SURGE (≈ 5 307 REPOSSESSED et 623 PAID_OFF au 04/11)
-- SELECT categorie, contract_status, COUNT(*) FROM gold.unified_contracts
-- WHERE statut_corrige_surge GROUP BY 1, 2 ORDER BY 1, 2;
--
-- 4. Migrés sans correspondance SURGE (attendu : 2 ou 3)
-- SELECT contract_number, categorie FROM gold.unified_contracts
-- WHERE origine = 'surge'
--   AND numero_origine NOT IN (SELECT installation_id::text FROM silver.surge_contracts);