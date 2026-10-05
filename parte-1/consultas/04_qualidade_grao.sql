-- ============================================================================
-- Prova do grão: a chave declarada não se repete e não tem nulo.
-- linhas = chaves_distintas, chaves_repetidas = 0 e linhas_com_chave_nula = 0
--   =>  1 linha por (ano, turno, cargo, UF, município, zona, candidato).
-- ============================================================================
WITH por_chave AS (
    SELECT ano_eleicao, nr_turno, cd_cargo, sg_uf, cd_municipio, nr_zona, sq_candidato,
           COUNT(*)                     AS n,
           COUNT_IF(qt_votos_validos < 0) AS negativos
    FROM trusted_votos_validos_zona
    GROUP BY 1, 2, 3, 4, 5, 6, 7
)
SELECT
    SUM(n)                    AS linhas,
    COUNT(*)                  AS chaves_distintas,
    COUNT_IF(n > 1)           AS chaves_repetidas,
    SUM(CASE WHEN ano_eleicao IS NULL OR nr_turno IS NULL OR cd_cargo IS NULL OR sg_uf IS NULL
                  OR cd_municipio IS NULL OR nr_zona IS NULL OR sq_candidato IS NULL
             THEN n ELSE 0 END) AS linhas_com_chave_nula,
    SUM(negativos)            AS votos_negativos
FROM por_chave
