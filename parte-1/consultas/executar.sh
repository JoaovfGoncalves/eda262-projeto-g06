#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Executa um .sql no Athena e MEDE o custo: bytes varridos, MB cobrados, US$.
# Grava o histórico em evidencias/custos.csv e o resultado em evidencias/.
#
# Uso (da raiz do repositório):
#   ./parte-1/consultas/executar.sh parte-1/consultas/01_pergunta_votos_validos_por_regiao.sql
#   ./parte-1/consultas/executar.sh parte-1/consultas/03_mesma_pergunta_na_raw.sql --sem-teto
#
# --sem-teto roda no workgroup "primary" da conta (que não é nosso e não tem
# teto), gravando o resultado no bucket de resultados do grupo. Serve só para
# medir o varrimento completo de uma consulta que o nosso teto mataria.
# ----------------------------------------------------------------------------
set -euo pipefail
source "$(cd "$(dirname "$0")/../.." && pwd)/verificacao/lib_athena.sh"

[[ $# -ge 1 && -f "$1" ]] || { echo "uso: $0 <arquivo.sql> [--sem-teto]"; exit 1; }
arquivo="$1"; modo="${2:-}"
carregar_saidas || { echo "Não li os outputs do Terraform. Rode o deploy antes (scripts/deploy.sh)."; exit 1; }

nome=$(basename "$arquivo" .sql)
wg="$WG"; out=""
if [[ "$modo" == "--sem-teto" ]]; then
  wg="primary"; out="s3://$BUCKET_RES/medicao-sem-teto/"
  nome="${nome}__sem-teto"
fi

echo "consulta : $arquivo"
echo "workgroup: $wg   database: $DB"
athena_executar "$(sql_de_arquivo "$arquivo")" "$wg" "$DB" "$out" || true
registrar_custo "$nome" "$wg"

echo "estado   : $ATH_ESTADO ${ATH_MOTIVO:+— $ATH_MOTIVO}"
echo "varrido  : $(fmt_bytes "$ATH_BYTES")"
echo "cobrado  : ${ATH_MB_COBRADOS} MB  =>  US\$ ${ATH_CUSTO_USD}   (US\$ 5/TB, mínimo 10 MB)"
echo "tempo    : ${ATH_MS} ms   id: $ATH_QID"

if [[ "$ATH_ESTADO" == "SUCCEEDED" ]]; then
  mkdir -p "$EVID"
  athena_resultado_tsv > "$EVID/resultado_${nome}.tsv"
  echo "resultado: evidencias/resultado_${nome}.tsv ($(($(wc -l < "$EVID/resultado_${nome}.tsv") - 1)) linhas)"
  echo
  head -n 20 "$EVID/resultado_${nome}.tsv" | column -t -s $'\t' 2>/dev/null || head -n 20 "$EVID/resultado_${nome}.tsv"
fi
