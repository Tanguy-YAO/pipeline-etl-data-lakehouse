-- ============================================================================
-- gold/recouvrement_rafraichir.sql  (v6.8, 11/11/2026)
-- Définition en vigueur de recouvrement.rafraichir(), appelée par l'étape
-- « Recouvrement - Rafraichissement table contrats » du pipeline.
--
-- Historique :
--   v6.6 : gel mensuel GREENO (gel_mensuel) puis copie vw_contrats → contrats
--          (gold/recouvrement_views.sql).
--   v6.7 (09/11/2026) : appel de recouvrement.attribuer_neotci() après la copie
--          (gold/recouvrement_attribution_neotci.sql).
--   v6.8 (11/11/2026) : produits Hotspot exclus du recouvrement. Le filtre est
--          posé au remplissage de la table : contrats_tevia, contrats_greeno et
--          contrats_neotci les perdent sans être modifiées ; vw_contrats reste
--          complète (11 contrats « TEVIA Hotspot » actifs le 11/11).
--
-- Ce fichier fait foi pour rafraichir() : il remplace les définitions plus
-- anciennes présentes dans recouvrement_views.sql et dans les scripts NEoTCI.
-- À relancer après tout script qui recrée la fonction.
-- ============================================================================

CREATE OR REPLACE FUNCTION recouvrement.rafraichir()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM recouvrement.gel_mensuel
                   WHERE mois = date_trunc('month', CURRENT_DATE)::date) THEN
        INSERT INTO recouvrement.gel_mensuel (mois, numero_contrat, jours_retard_debut_mois, source)
        SELECT date_trunc('month', CURRENT_DATE)::date, numero_contrat, jours_retard_greeno, 'delta'
        FROM recouvrement.vw_contrats
        WHERE categorie = 'upya_greeno'
          AND jours_retard_greeno IS NOT NULL;
    END IF;

    DELETE FROM recouvrement.contrats;

    -- v6.8 : produits Hotspot exclus du recouvrement
    INSERT INTO recouvrement.contrats
    SELECT * FROM recouvrement.vw_contrats
    WHERE COALESCE(produit, '') !~* 'hot\s*-?\s*spot';

    -- v6.7 : attribution NEoTCI (ajouts du jour uniquement, table protégée)
    PERFORM recouvrement.attribuer_neotci();
END;
$$;

-- Contrôle (doit renvoyer 0) :
-- SELECT COUNT(*) FROM recouvrement.contrats WHERE produit ~* 'hot\s*-?\s*spot';
