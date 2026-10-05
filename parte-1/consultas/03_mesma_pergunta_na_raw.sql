-- ============================================================================
-- COMPARAÇÃO DE CUSTO: o recorte da consulta 02, só que direto na RAW.
-- Serve para medir quanto a camada trusted economiza. Repare no que a raw
-- obriga a fazer: CAST de texto, mapear UF -> região na mão e conviver com
-- acentos quebrados (o arquivo é ISO-8859-1).
-- Ela NÃO filtra votos válidos com rigor: o resultado é aproximado de propósito.
--
-- No workgroup do grupo esta consulta MORRE no teto de bytes (é o esperado).
-- Para medir o varrimento completo: ./parte-1/consultas/executar.sh <este arquivo> --sem-teto
-- ============================================================================
WITH raw AS (
    SELECT ano_eleicao, nr_turno, cd_cargo, sg_uf, nm_urna_candidato, qt_votos_nominais
    FROM raw_votacao_candidato_munzona_2018
    UNION ALL
    SELECT ano_eleicao, nr_turno, cd_cargo, sg_uf, nm_urna_candidato, qt_votos_nominais
    FROM raw_votacao_candidato_munzona_2022
)
SELECT
    CAST(ano_eleicao AS integer) AS ano_eleicao,
    CASE
        WHEN sg_uf IN ('AC','AM','AP','PA','RO','RR','TO')                THEN 'N'
        WHEN sg_uf IN ('AL','BA','CE','MA','PB','PE','PI','RN','SE')      THEN 'NE'
        WHEN sg_uf IN ('DF','GO','MS','MT')                               THEN 'CO'
        WHEN sg_uf IN ('ES','MG','RJ','SP')                               THEN 'SE'
        WHEN sg_uf IN ('PR','RS','SC')                                    THEN 'S'
        ELSE 'EX'
    END                                                     AS regiao,
    nm_urna_candidato,
    SUM(TRY_CAST(qt_votos_nominais AS bigint))              AS votos_nominais
FROM raw
WHERE cd_cargo = '1' AND nr_turno = '2'
GROUP BY 1, 2, 3
ORDER BY 1, 2, 4 DESC
