-- ============================================================
-- gold/greeno_contracts.sql
-- Vue filtrée GREENO uniquement
-- Source : gold.unified_contracts WHERE entite = 'GREENO'
-- Inclut : upya_greeno
-- ============================================================
CREATE OR REPLACE VIEW gold.greeno_contracts AS
SELECT * FROM gold.unified_contracts
WHERE entite = 'GREENO';
