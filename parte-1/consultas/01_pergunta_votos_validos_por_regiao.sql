-- ============================================================================
-- PERGUNTA DE NEGÓCIO (descritiva)
-- Como os votos válidos para Presidente, Governador e Senador se distribuíram
-- em cada região do Brasil (N, NE, CO, SE, S e exterior), no 1º e no 2º turno
-- das eleições gerais de 2018 e 2022?
--
-- Presidente: por candidato (a disputa é a mesma no país inteiro).
-- Governador e Senador: por PARTIDO, porque cada UF tem candidatos próprios e
-- somar "candidatos" de estados diferentes numa região não faz sentido.
-- Percentual sobre os votos válidos da região, do cargo e do turno.
-- Mostra os 3 primeiros de cada recorte.
-- ============================================================================
WITH por_regiao AS (
    SELECT
        ano_eleicao,
        nr_turno,
        cd_cargo,
        ds_cargo,
        regiao,
        COALESCE(sg_partido, '(sem sigla)')                    AS sg_partido,
        CASE WHEN cd_cargo = 1 THEN nm_urna_candidato END      AS candidato_presidente,
        SUM(qt_votos_validos)                                  AS votos_validos
    FROM trusted_votos_validos_zona
    GROUP BY 1, 2, 3, 4, 5, 6, 7
),
com_percentual AS (
    SELECT
        *,
        ROUND(100 * CAST(votos_validos AS double)
              / SUM(votos_validos) OVER (PARTITION BY ano_eleicao, nr_turno, cd_cargo, regiao), 2)
                                                               AS pct_votos_validos,
        RANK() OVER (PARTITION BY ano_eleicao, nr_turno, cd_cargo, regiao
                     ORDER BY votos_validos DESC)              AS posicao
    FROM por_regiao
)
SELECT
    ano_eleicao,
    nr_turno,
    ds_cargo,
    regiao,
    posicao,
    sg_partido,
    candidato_presidente,
    votos_validos,
    pct_votos_validos
FROM com_percentual
WHERE posicao <= 3
ORDER BY
    ano_eleicao,
    nr_turno,
    cd_cargo,
    CASE regiao WHEN 'N' THEN 1 WHEN 'NE' THEN 2 WHEN 'CO' THEN 3
                WHEN 'SE' THEN 4 WHEN 'S' THEN 5 ELSE 6 END,
    posicao
