#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Sobe a Parte 1 do zero, em conta limpa:
#   1. bootstrap do backend (bucket de state + tabela de lock), state local
#   2. gera infra/backend.hcl a partir dos outputs do bootstrap
#   3. init da stack com backend remoto, seleciona/cria o workspace "av1"
#   4. apply da stack (módulo lake)
# Uso (da raiz do repo):  ./parte-1/scripts/deploy.sh [--auto-approve]
# ----------------------------------------------------------------------------
set -euo pipefail
PARTE1="$(cd "$(dirname "$0")/.." && pwd)"
source "$PARTE1/../verificacao/lib_athena.sh"   # define REGIAO a partir do terraform.tfvars
WORKSPACE="${WORKSPACE:-av1}"
AUTO="${1:-}"

for bin in terraform aws; do command -v "$bin" >/dev/null || { echo "falta $bin"; exit 1; }; done
echo "Conta: $(aws sts get-caller-identity --query Account --output text)  Região: $REGIAO (de parte-1/infra/terraform.tfvars)"

ls "$PARTE1"/dados/trusted/votos_validos_zona/*.tsv* >/dev/null 2>&1 \
  || { echo "Sem dados em parte-1/dados/. Rode antes: python3 parte-1/dados/preparar_dados.py"; exit 1; }
ls "$PARTE1"/infra/modules/lake/schemas/*.json >/dev/null 2>&1 \
  || { echo "Sem schema da raw em infra/modules/lake/schemas/. Rode preparar_dados.py."; exit 1; }

echo; echo "== 1/3 bootstrap do backend remoto"
terraform -chdir="$PARTE1/bootstrap" init -input=false
terraform -chdir="$PARTE1/bootstrap" apply -input=false -auto-approve -var "regiao=$REGIAO"
terraform -chdir="$PARTE1/bootstrap" output -raw backend_hcl > "$PARTE1/infra/backend.hcl"
echo "backend.hcl gerado:"; sed 's/^/   /' "$PARTE1/infra/backend.hcl"

echo; echo "== 2/3 init com backend remoto + workspace '$WORKSPACE'"
terraform -chdir="$PARTE1/infra" init -input=false -reconfigure -backend-config=backend.hcl
terraform -chdir="$PARTE1/infra" workspace select "$WORKSPACE" 2>/dev/null \
  || terraform -chdir="$PARTE1/infra" workspace new "$WORKSPACE"

echo; echo "== 3/3 apply"
if [[ "$AUTO" == "--auto-approve" ]]; then
  terraform -chdir="$PARTE1/infra" apply -input=false -auto-approve
else
  terraform -chdir="$PARTE1/infra" apply -input=false
fi

echo; echo "Pronto. Próximo passo: ./verificacao/verifica.sh"