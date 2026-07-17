-- ============================================================
-- gold/tevia_contracts.sql
-- Vue filtrée TEVIA uniquement
-- Source : gold.unified_contracts WHERE entite = 'TEVIA'
-- Inclut : upya_tevia + surge_tevia + surge_neotci + surge_zeci
-- ============================================================
CREATE OR REPLACE VIEW gold.tevia_contracts AS
SELECT * FROM gold.unified_contracts
WHERE entite = 'TEVIA';
