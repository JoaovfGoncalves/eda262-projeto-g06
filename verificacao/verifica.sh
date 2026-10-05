#!/usr/bin/env bash
# ============================================================================
# verifica.sh — script de aceite da PARTE 1 (AV1) · grupo g06
#
# Roda na conta de quem avalia e imprime [PASSA]/[FALHA] por critério.
#   ./verificacao/verifica.sh                 # depois do deploy
#   ./verificacao/verifica.sh --pos-destroy   # depois do destroy: nada pode sobrar
#
# A saída também é gravada em evidencias/verifica_<modo>_<data>.txt
# ============================================================================
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib_athena.sh"

MODO="${1:-}"
mkdir -p "$EVID"
SAIDA="$EVID/verifica_$([[ "$MODO" == "--pos-destroy" ]] && echo pos-destroy || echo deploy)_$(date -u +%Y%m%dT%H%M%SZ).txt"
exec > >(tee "$SAIDA") 2>&1

PASSOU=0; FALHOU=0
passa() { echo "[PASSA] [$1] $2"; PASSOU=$((PASSOU + 1)); }
falha() { echo "[FALHA] [$1] $2"; FALHOU=$((FALHOU + 1)); }
info()  { echo "        $*"; }

for bin in aws jq terraform awk; do
  command -v "$bin" >/dev/null || { echo "dependência ausente: $bin"; exit 1; }
done
CONTA=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || { echo "Sem credenciais AWS válidas."; exit 1; }
echo "== verifica.sh · Parte 1 · $PREFIXO · conta $CONTA · região $REGIAO · $(date -u +%FT%TZ)"
echo

tem_tags() { # recebe JSON com as tags normalizadas em {chave: valor}
  jq -e --arg g "$GRUPO" '.turma == "eda262" and .grupo == $g and .projeto == "engenharia-de-dados"' >/dev/null
}

# ============================================================================
if [[ "$MODO" == "--pos-destroy" ]]; then
# ============================================================================
  sobras=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '$PREFIXO-')].Name" --output text)
  [[ -z "$sobras" || "$sobras" == "None" ]] && passa P1 "nenhum bucket $PREFIXO-* na conta" \
                                            || falha P1 "buckets órfãos: $sobras"

  db="${PREFIXO//-/_}_eleicoes"
  aws glue get-database --region "$REGIAO" --name "$db" >/dev/null 2>&1 \
    && falha P2 "database $db ainda existe" || passa P2 "database $db não existe"

  aws athena get-work-group --region "$REGIAO" --work-group "$PREFIXO-wg" >/dev/null 2>&1 \
    && falha P3 "workgroup $PREFIXO-wg ainda existe" || passa P3 "workgroup $PREFIXO-wg não existe"

  aws dynamodb describe-table --region "$REGIAO" --table-name "$PREFIXO-tflock" >/dev/null 2>&1 \
    && falha P4 "tabela de lock $PREFIXO-tflock ainda existe (rodou o destroy do bootstrap?)" \
    || passa P4 "tabela de lock $PREFIXO-tflock não existe"

  # A API de tags é eventualmente consistente: um recurso recém-apagado pode
  # aparecer por alguns minutos. Por isso tentamos algumas vezes.
  for tentativa in 1 2 3; do
    arns=$(aws resourcegroupstaggingapi get-resources --region "$REGIAO" \
            --tag-filters "Key=grupo,Values=$GRUPO" "Key=turma,Values=eda262" \
            --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null)
    [[ -z "$arns" || "$arns" == "None" ]] && break
    [[ $tentativa -lt 3 ]] && sleep 20
  done
  [[ -z "$arns" || "$arns" == "None" ]] && passa P5 "nenhum recurso com as tags turma=eda262, grupo=$GRUPO" \
                                        || falha P5 "recursos com as tags do grupo: $arns"
else
# ============================================================================
  # [0] Eliminatório: schema declarado, nenhum Crawler
  if grep -rqE 'aws_glue_crawler|AWS::Glue::Crawler' "$RAIZ/parte-1" --include='*.tf' --include='*.json' --include='*.yaml'; then
    falha 0 "existe Crawler no código — ELIMINATÓRIO"; echo; echo "Resultado: ELIMINADO"; exit 1
  fi
  crawlers=$(aws glue list-crawlers --region "$REGIAO" --query "CrawlerNames[?starts_with(@, '$PREFIXO')]" --output text 2>/dev/null)
  [[ -n "$crawlers" ]] && { falha 0 "Crawler na conta: $crawlers — ELIMINATÓRIO"; exit 1; }
  passa 0 "nenhum Crawler: nem no código, nem na conta"

  if ! carregar_saidas; then
    falha 1 "não consegui ler os outputs do Terraform em parte-1/infra (deploy feito? terraform init rodado?)"
    echo; echo "Resultado: $PASSOU PASSA · $FALHOU FALHA"; exit 1
  fi

  # [1] Módulo + backend remoto (S3 + DynamoDB) + workspace
  ok=1
  grep -qE '^module "lake"' "$INFRA/main.tf"                   || { ok=0; info "sem module \"lake\" em infra/main.tf"; }
  [[ -z "$(grep -lE '^resource ' "$INFRA"/*.tf 2>/dev/null)" ]] || { ok=0; info "há resource solto na raiz (deveria estar no módulo)"; }
  grep -qE 'backend "s3"' "$INFRA/versions.tf"                 || { ok=0; info "sem backend \"s3\""; }
  tipo=$(jq -r '.backend.type // ""' "$INFRA/.terraform/terraform.tfstate" 2>/dev/null)
  lock=$(jq -r '.backend.config.dynamodb_table // ""' "$INFRA/.terraform/terraform.tfstate" 2>/dev/null)
  [[ "$tipo" == "s3" && -n "$lock" ]]                          || { ok=0; info "backend inicializado: '$tipo', lock: '$lock'"; }
  ws=$(terraform -chdir="$INFRA" workspace show 2>/dev/null)
  [[ -n "$ws" && "$ws" != "default" ]]                         || { ok=0; info "workspace em uso: '$ws' (esperado um workspace nomeado)"; }
  ls "$INFRA"/terraform.tfstate >/dev/null 2>&1                && { ok=0; info "há terraform.tfstate LOCAL em infra/"; }
  [[ $ok -eq 1 ]] && passa 1 "módulo lake + backend s3 com lock DynamoDB ($lock) + workspace '$ws'" \
                  || falha 1 "módulo/backend/workspace incompletos"

  # [2] Recursos provisionados, nomenclatura e as 3 tags obrigatórias
  ok=1
  for b in "$BUCKET_RAW" "$BUCKET_TRUSTED" "$BUCKET_RES"; do
    [[ "$b" == "$PREFIXO-"* ]] || { ok=0; info "bucket fora do padrão: $b"; }
    aws s3api get-bucket-tagging --bucket "$b" --output json 2>/dev/null \
      | jq '.TagSet | map({key: .Key, value: .Value}) | from_entries' | tem_tags || { ok=0; info "bucket sem tags obrigatórias: $b"; }
  done
  aws glue get-database --region "$REGIAO" --name "$DB" >/dev/null 2>&1 || { ok=0; info "database $DB não existe"; }
  aws glue get-tags --region "$REGIAO" --resource-arn "arn:aws:glue:$REGIAO:$CONTA:database/$DB" --output json 2>/dev/null \
    | jq '.Tags' | tem_tags || { ok=0; info "database sem tags obrigatórias"; }
  aws athena list-tags-for-resource --region "$REGIAO" --resource-arn "arn:aws:athena:$REGIAO:$CONTA:workgroup/$WG" --output json 2>/dev/null \
    | jq '.Tags | map({key: .Key, value: .Value}) | from_entries' | tem_tags || { ok=0; info "workgroup $WG ausente ou sem tags"; }
  arn_lock=$(aws dynamodb describe-table --region "$REGIAO" --table-name "$PREFIXO-tflock" --query Table.TableArn --output text 2>/dev/null)
  aws dynamodb list-tags-of-resource --region "$REGIAO" --resource-arn "$arn_lock" --output json 2>/dev/null \
    | jq '.Tags | map({key: .Key, value: .Value}) | from_entries' | tem_tags || { ok=0; info "tabela de lock ausente ou sem tags"; }
  [[ $ok -eq 1 ]] && passa 2 "3 buckets, database, workgroup e lock: prefixo $PREFIXO- e tags turma/grupo/projeto" \
                  || falha 2 "nomenclatura ou tags obrigatórias"

  # [3] Schema declarado: trusted tipada, com grão e chave; raw por ano
  t=$(aws glue get-table --region "$REGIAO" --database-name "$DB" --name "$TB_TRUSTED" --output json 2>/dev/null) || t='{}'
  ncol=$(jq '.Table.StorageDescriptor.Columns // [] | length' <<<"$t")
  ntip=$(jq '[.Table.StorageDescriptor.Columns // [] | .[] | select(.Type != "string")] | length' <<<"$t")
  grao=$(jq -r '.Table.Parameters.grao // ""' <<<"$t")
  chave=$(jq -r '.Table.Parameters.chave_primaria // ""' <<<"$t")
  nraw=$(aws glue get-tables --region "$REGIAO" --database-name "$DB" --expression 'raw_.*' --query 'length(TableList)' --output text 2>/dev/null)
  if [[ "$ncol" -ge 10 && "$ntip" -ge 5 && -n "$grao" && -n "$chave" && "${nraw:-0}" -ge 2 ]]; then
    passa 3 "trusted com $ncol colunas ($ntip tipadas), grão e chave declarados; $nraw tabelas raw"
    info "grão : $grao"; info "chave: $chave"
  else
    falha 3 "schema: colunas=$ncol tipadas=$ntip grão='${grao:0:20}' chave='${chave:0:20}' raw=$nraw"
  fi

  # [4] O grão vale nos dados: chave única, sem nulo, sem voto negativo
  athena_executar "$(sql_de_arquivo "$RAIZ/parte-1/consultas/04_qualidade_grao.sql")" "$WG" "$DB"
  registrar_custo "04_qualidade_grao" "$WG"
  if [[ "$ATH_ESTADO" == "SUCCEEDED" ]]; then
    read -r linhas distintas repetidas nulas negativos < <(athena_resultado_tsv | sed -n 2p)
    if [[ "$linhas" -gt 0 && "$linhas" == "$distintas" && "$repetidas" == 0 && "$nulas" == 0 && "$negativos" == 0 ]]; then
      passa 4 "grão respeitado: $linhas linhas = $distintas chaves distintas, 0 repetidas, 0 nulas"
    else
      falha 4 "grão violado: linhas=$linhas distintas=$distintas repetidas=$repetidas nulas=$nulas negativos=$negativos"
    fi
  else
    falha 4 "consulta de grão: $ATH_ESTADO $ATH_MOTIVO"
  fi

  # [5] Reconciliação com o resultado oficial do TSE (Presidente, 2º turno)
  sql="SELECT ano_eleicao, nr_candidato, SUM(qt_votos_validos) FROM $TB_TRUSTED
       WHERE cd_cargo = 1 AND nr_turno = 2 GROUP BY 1, 2 ORDER BY 1, 2"
  athena_executar "$sql" "$WG" "$DB"; registrar_custo "reconciliacao_presidente_2t" "$WG"
  esperado=$'2018\t13\t47040906\n2018\t17\t57797847\n2022\t13\t60345999\n2022\t22\t58206354'
  obtido=$(athena_resultado_tsv 2>/dev/null | tail -n +2)
  if [[ "$ATH_ESTADO" == "SUCCEEDED" && "$obtido" == "$esperado" ]]; then
    passa 5 "votos válidos do 2º turno batem com o TSE, voto a voto (2018 e 2022)"
  else
    falha 5 "reconciliação com o TSE não bate ($ATH_ESTADO)"; info "esperado: ${esperado//$'\n'/ | }"; info "obtido  : ${obtido//$'\n'/ | }"
  fi

  # [6] A pergunta de negócio respondida no Athena, com custo medido
  athena_executar "$(sql_de_arquivo "$RAIZ/parte-1/consultas/01_pergunta_votos_validos_por_regiao.sql")" "$WG" "$DB"
  registrar_custo "01_pergunta_votos_validos_por_regiao" "$WG"
  if [[ "$ATH_ESTADO" == "SUCCEEDED" ]]; then
    athena_resultado_tsv > "$EVID/resultado_01_pergunta_votos_validos_por_regiao.tsv"
    n=$(($(wc -l < "$EVID/resultado_01_pergunta_votos_validos_por_regiao.tsv") - 1))
    regs=$(cut -f4 "$EVID/resultado_01_pergunta_votos_validos_por_regiao.tsv" | tail -n +2 | sort -u | tr '\n' ' ')
    if [[ $n -gt 0 ]]; then
      passa 6 "pergunta respondida: $n linhas, regiões: $regs"
      info "varrido $(fmt_bytes "$ATH_BYTES") · cobrado ${ATH_MB_COBRADOS} MB · US\$ $ATH_CUSTO_USD · ${ATH_MS} ms"
    else
      falha 6 "a pergunta não devolveu linhas"
    fi
  else
    falha 6 "pergunta: $ATH_ESTADO $ATH_MOTIVO"
  fi
  CUSTO_PERGUNTA="$ATH_BYTES"

  # [7] O teto mata a varredura larga da raw e deixa passar a pergunta (trusted)
  athena_executar "$(sql_de_arquivo "$RAIZ/parte-1/consultas/03_mesma_pergunta_na_raw.sql")" "$WG" "$DB"
  registrar_custo "03_mesma_pergunta_na_raw" "$WG"
  if [[ "$ATH_ESTADO" != "SUCCEEDED" && "$ATH_MOTIVO" == *[Ll]imit* && "$CUSTO_PERGUNTA" -gt 0 && "$CUSTO_PERGUNTA" -lt "$TETO" ]]; then
    passa 7 "teto de $(fmt_bytes "$TETO"): raw morreu ($ATH_ESTADO), trusted passou com $(fmt_bytes "$CUSTO_PERGUNTA")"
  else
    falha 7 "teto não separou raw de trusted: raw=$ATH_ESTADO ($ATH_MOTIVO), trusted=$CUSTO_PERGUNTA, teto=$TETO"
  fi

  # [8] DECISOES.md com as cinco decisões e sem número pendente
  arq="$RAIZ/DECISOES.md"; ok=1
  for s in "Grão" "Chave" "Partição" "Formato" "Custo"; do
    grep -qiE "^#+ .*$s" "$arq" 2>/dev/null || { ok=0; info "seção ausente: $s"; }
  done
  pend=$(grep -c '«MEDIR' "$arq" 2>/dev/null); pend=${pend:-0}
  [[ "$pend" -eq 0 ]] || { ok=0; info "$pend número(s) ainda marcados «MEDIR…» no DECISOES.md"; }
  [[ $ok -eq 1 ]] && passa 8 "DECISOES.md: grão, chave, partição, formato e custo, sem pendências" \
                  || falha 8 "DECISOES.md incompleto"
fi

echo
echo "Resultado: $PASSOU PASSA · $FALHOU FALHA"
echo "Evidência gravada em ${SAIDA#$RAIZ/}"
[[ $FALHOU -eq 0 ]]
