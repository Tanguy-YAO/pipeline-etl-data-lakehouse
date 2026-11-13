-- ============================================================================
-- pdg-photo-v4.sql  (12/11/2026)  d'un bloc dans pgAdmin
-- Portefeuille à une photo choisie, pour le filtre « Photo » du tableau de
-- bord de la direction (mêmes libellés que le comité crédit : « Dernière
-- photo », « 2026-10-31 · samedi · fin de mois »…), avec les valeurs de la
-- photo précédente pour mesurer l'évolution.
-- ============================================================================

CREATE OR REPLACE VIEW pdg.v_portefeuille_photo AS
WITH p AS (
    SELECT pj.*,
           LAG(pj.jour)           OVER w AS jour_prec,
           LAG(pj.actifs)         OVER w AS actifs_prec,
           LAG(pj.encours)        OVER w AS encours_prec,
           LAG(pj.encours_par30)  OVER w AS encours_par30_prec,
           LAG(pj.encours_par90)  OVER w AS encours_par90_prec,
           LAG(pj.encours_par180) OVER w AS encours_par180_prec
    FROM pdg.v_portefeuille_jour pj
    WINDOW w AS (PARTITION BY pj.entite, pj.categorie ORDER BY pj.jour)
)
SELECT ch.photo, p.*
FROM bi.v_choix_photo ch
JOIN p ON p.jour = ch.date_photo;

COMMENT ON VIEW pdg.v_portefeuille_photo IS
'Portefeuille par entité et type de client à une photo choisie (colonne photo : « Dernière photo » ou le libellé d''une date), avec les montants de la photo précédente (colonnes *_prec) pour calculer les évolutions. Filtrer toujours sur une seule photo : sans filtre, les dates s''additionnent.';
COMMENT ON COLUMN pdg.v_portefeuille_photo.photo IS 'Libellé de la photo : « Dernière photo » (la plus récente) ou « AAAA-MM-JJ · jour [· comité] [· fin de mois] »';
COMMENT ON COLUMN pdg.v_portefeuille_photo.jour_prec IS 'Date de la photo précédente';

GRANT SELECT ON pdg.v_portefeuille_photo TO pdg_lecture, role_read;

-- Contrôle : dernière photo
SELECT entite, categorie, actifs, encours, par30, jour_prec, encours_prec
FROM pdg.v_portefeuille_photo WHERE photo = 'Dernière photo' ORDER BY 1, 2;
