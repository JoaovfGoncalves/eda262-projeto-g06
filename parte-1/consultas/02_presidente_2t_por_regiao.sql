-- ============================================================================
-- Recorte da pergunta: 2º turno para Presidente, 2018 x 2022, por região.
-- Para cada região: quem ficou à frente, com que percentual dos votos válidos
-- e qual a margem em pontos percentuais.
-- ============================================================================
WITH por_regiao AS (
    SELECT ano_eleicao, regiao, nm_urna_candidato, sg_partido,
           SUM(qt_votos_validos) AS votos_validos
    FROM trusted_votos_validos_zona
    WHERE cd_cargo = 1 AND nr_turno = 2
    GROUP BY 1, 2, 3, 4
),
ranqueado AS (
    SELECT *,
           100 * CAST(votos_validos AS double) / SUM(votos_validos) OVER (PARTITION BY ano_eleicao, regiao) AS pct,
           ROW_NUMBER() OVER (PARTITION BY ano_eleicao, regiao ORDER BY votos_validos DESC) AS pos
    FROM por_regiao
)
SELECT
    ano_eleicao,
    regiao,
    MAX(CASE WHEN pos = 1 THEN nm_urna_candidato || ' (' || sg_partido || ')' END) AS a_frente,
    ROUND(MAX(CASE WHEN pos = 1 THEN pct END), 2)                                  AS pct_a_frente,
    MAX(CASE WHEN pos = 2 THEN nm_urna_candidato || ' (' || sg_partido || ')' END) AS segundo,
    ROUND(MAX(CASE WHEN pos = 2 THEN pct END), 2)                                  AS pct_segundo,
    ROUND(MAX(CASE WHEN pos = 1 THEN pct END) - MAX(CASE WHEN pos = 2 THEN pct END), 2) AS margem_pp,
    SUM(CASE WHEN pos IN (1, 2) THEN votos_validos END)                            AS votos_validos_regiao
FROM ranqueado
GROUP BY ano_eleicao, regiao
ORDER BY ano_eleicao,
         CASE regiao WHEN 'N' THEN 1 WHEN 'NE' THEN 2 WHEN 'CO' THEN 3
                     WHEN 'SE' THEN 4 WHEN 'S' THEN 5 ELSE 6 END