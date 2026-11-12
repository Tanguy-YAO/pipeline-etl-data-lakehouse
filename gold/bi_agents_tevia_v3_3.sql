-- ============================================================================
-- bi-agents-tevia-v3.3.sql  (12/11/2026, v3.3.1 : numéros en T des surge_tevia)
-- Agent de crédit TEVIA dans le tableau de bord du comité (Metabase).
--
-- Source : silver.greeno_client_contrat_tevia (application GREENO), colonne
--   agent_credit. Les numéros y sont stockés sans zéro initial et sans le
--   préfixe T des migrés SURGE : la jointure se fait sur le numéro débarrassé
--   des deux.
-- Avant d'exécuter : relancer le chargeur GREENO corrigé (la table était
--   figée au 20/10), puis SELECT recouvrement.rafraichir();
--
-- Exécution : tout le fichier d'un bloc dans pgAdmin (environ 1 à 3 minutes).
-- ============================================================================

-- 1. Attributs actuels : ajout de l'agent de crédit TEVIA
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
    -- v3.3 : agent de crédit TEVIA (application GREENO)
    agents_tevia AS (
        -- v3.3.1 : clé sans préfixe T et sans zéro initial des deux côtés ; la
        -- table GREENO écrit les numéros tantôt « 734015 », tantôt « T734015 »,
        -- tantôt « 072410436 », tantôt « 72410436 » selon les chargements
        SELECT DISTINCT ON (ltrim(regexp_replace(contract_number::text, '^T', ''), '0'))
               ltrim(regexp_replace(contract_number::text, '^T', ''), '0') AS cle,
               NULLIF(TRIM(agent_credit), '')                              AS agent
        FROM silver.greeno_client_contrat_tevia
        WHERE NULLIF(TRIM(agent_credit), '') IS NOT NULL
        ORDER BY ltrim(regexp_replace(contract_number::text, '^T', ''), '0'), loaded_at DESC
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
        COALESCE(n.agent, g.agent, ta.agent, 'Non attribué'),
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
    LEFT JOIN agents_tevia ta
           ON r.entite = 'TEVIA'
          AND ta.cle = ltrim(regexp_replace(c.contract_number::text, '^T', ''), '0')
    LEFT JOIN techniciens tk ON tk.numero_contrat = c.contract_number::text
    WHERE c.deal_type = 'PAYG'
      AND c.contract_status <> 'CANCELLED'
    ON CONFLICT (numero_contrat) DO NOTHING;

    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;


-- 2. Rattrapage du passé : les acteurs sont ceux d'aujourd'hui pour les dates
--    déjà enregistrées (même règle que les autres acteurs). On complète les
--    versions TEVIA restées « Non attribué », puis on recalcule les agrégats
--    par date et la collecte, qui portent l'agent.
SELECT bi.rafraichir_attributs();

UPDATE bi.contrat_attributs ca
SET agent_recouvrement = x.agent_recouvrement
FROM bi.attributs_contrat x
WHERE x.numero_contrat = ca.numero_contrat
  AND x.entite = 'TEVIA'
  AND x.agent_recouvrement <> 'Non attribué'
  AND COALESCE(ca.agent_recouvrement, 'Non attribué') = 'Non attribué';

DO $$
DECLARE d date;
BEGIN
    FOR d IN SELECT date_photo FROM bi.calendrier ORDER BY 1 LOOP
        DELETE FROM bi.indicateurs_jour WHERE date_photo = d;
        INSERT INTO bi.indicateurs_jour
        SELECT date_photo, perimetre, entite, categorie, regional, dsm, commercial, agent_recouvrement,
               SUM(nb_actifs), SUM(encours), SUM(encours_par1), SUM(encours_par30), SUM(encours_par60),
               SUM(encours_par90), SUM(encours_par120), SUM(encours_par180),
               SUM(nb_fpd_evaluables), SUM(nb_fpd), SUM(encours_fpd)
        FROM bi.v_portefeuille_date
        WHERE date_photo = d
        GROUP BY 1, 2, 3, 4, 5, 6, 7, 8;
    END LOOP;
END $$;

SELECT bi.rafraichir_collecte();


-- 3. Contrôle : actifs du comité TEVIA par agent à la dernière photo
SELECT agent_recouvrement, SUM(nb_actifs) AS actifs, ROUND(SUM(encours)) AS encours,
       ROUND(100 * SUM(encours_par30) / NULLIF(SUM(encours), 0), 1) AS par30
FROM bi.v_portefeuille
WHERE photo = 'Dernière photo' AND perimetre = 'Comité TEVIA'
GROUP BY ROLLUP (agent_recouvrement)
ORDER BY agent_recouvrement IS NULL, actifs DESC;
