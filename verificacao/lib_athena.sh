#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Funções compartilhadas por verifica.sh e parte-1/consultas/executar.sh.
# Dependências: aws CLI v2, jq, terraform, awk.
# ----------------------------------------------------------------------------
REGIAO="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA="$RAIZ/parte-1/infra"
EVID="$RAIZ/evidencias"
GRUPO="g06"
PREFIXO="eda262-$GRUPO"

# Lê os outputs de contrato da stack (precisa de terraform init já feito em infra/).
carregar_saidas() {
  local j
  j=$(terraform -chdir="$INFRA" output -json 2>/dev/null) || return 1
  WG=$(jq -r '.workgroup_name.value // empty' <<<"$j")
  DB=$(jq -r '.database_name.value // empty' <<<"$j")
  TB_TRUSTED=$(jq -r '.tabela_trusted.value // empty' <<<"$j")
  BUCKET_RAW=$(jq -r '.bucket_raw.value // empty' <<<"$j")
  BUCKET_TRUSTED=$(jq -r '.bucket_trusted.value // empty' <<<"$j")
  BUCKET_RES=$(jq -r '.bucket_resultados.value // empty' <<<"$j")
  TETO=$(jq -r '.teto_bytes.value // empty' <<<"$j")
  [[ -n "$WG" && -n "$DB" ]]
}

# Custo do Athena: US$ 5 por TB varrido, arredondado para cima ao MB,
# mínimo de 10 MB por consulta. Consulta sem varrimento (erro) não cobra.
athena_custo() {
  awk -v b="$1" 'BEGIN {
    if (b <= 0) { printf "0 0.00000000\n"; exit }
    mb = int((b + 1048575) / 1048576); if (mb < 10) mb = 10
    printf "%d %.8f\n", mb, mb * 1048576 / 1099511627776 * 5
  }'
}

# Lê um .sql e tira o ";" final (o Athena aceita um comando por execução).
sql_de_arquivo() {
  sed -e 's/[[:space:]]*;[[:space:]]*$//' "$1"
}

# athena_executar <sql> <workgroup> <database> [output_location]
# Define: ATH_QID ATH_ESTADO ATH_MOTIVO ATH_BYTES ATH_MS ATH_MB_COBRADOS ATH_CUSTO_USD
athena_executar() {
  local sql="$1" wg="$2" db="$3" out="${4:-}" j
  local args=(athena start-query-execution --region "$REGIAO" --work-group "$wg"
              --query-execution-context "Database=$db" --query-string "$sql"
              --output text --query QueryExecutionId)
  [[ -n "$out" ]] && args+=(--result-configuration "OutputLocation=$out")
  ATH_QID=$(aws "${args[@]}") || { ATH_ESTADO="ERRO_AO_SUBMETER"; ATH_BYTES=0; return 1; }
  while :; do
    j=$(aws athena get-query-execution --region "$REGIAO" --query-execution-id "$ATH_QID" --output json)
    ATH_ESTADO=$(jq -r '.QueryExecution.Status.State' <<<"$j")
    case "$ATH_ESTADO" in QUEUED|RUNNING) sleep 2 ;; *) break ;; esac
  done
  ATH_MOTIVO=$(jq -r '.QueryExecution.Status.StateChangeReason // ""' <<<"$j")
  ATH_BYTES=$(jq -r '.QueryExecution.Statistics.DataScannedInBytes // 0' <<<"$j")
  ATH_MS=$(jq -r '.QueryExecution.Statistics.EngineExecutionTimeInMillis // 0' <<<"$j")
  read -r ATH_MB_COBRADOS ATH_CUSTO_USD < <(athena_custo "$ATH_BYTES")
}

# Resultado da última consulta como TSV (com cabeçalho).
athena_resultado_tsv() {
  aws athena get-query-results --region "$REGIAO" --query-execution-id "$ATH_QID" --output json \
    | jq -r '.ResultSet.Rows[] | [.Data[] | (.VarCharValue // "")] | @tsv'
}

# Registra a medição em evidencias/custos.csv (histórico de custo por consulta).
registrar_custo() {
  local rotulo="$1" wg="$2"
  mkdir -p "$EVID"
  local arq="$EVID/custos.csv"
  [[ -f "$arq" ]] || echo "data_hora_utc,consulta,workgroup,estado,bytes_varridos,mb_cobrados,custo_usd,tempo_ms,query_execution_id" > "$arq"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$rotulo,$wg,$ATH_ESTADO,$ATH_BYTES,$ATH_MB_COBRADOS,$ATH_CUSTO_USD,$ATH_MS,$ATH_QID" >> "$arq"
}

fmt_bytes() { awk -v b="$1" 'BEGIN { printf "%d bytes (%.2f MB)", b, b/1048576 }'; }
