#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Derruba TUDO na ordem certa: primeiro a stack (que depende do backend),
# depois o workspace, por último o bootstrap do backend.
# Uso (da raiz do repo):  ./parte-1/scripts/destroy.sh [--auto-approve]
# Depois: ./verificacao/verifica.sh --pos-destroy
# ----------------------------------------------------------------------------
set -euo pipefail
PARTE1="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="${WORKSPACE:-av1}"
APROVA=(); [[ "${1:-}" == "--auto-approve" ]] && APROVA=(-auto-approve)

echo "== 1/3 destroy da stack (workspace '$WORKSPACE')"
terraform -chdir="$PARTE1/infra" workspace select "$WORKSPACE"
terraform -chdir="$PARTE1/infra" destroy -input=false ${APROVA[@]+"${APROVA[@]}"}

echo; echo "== 2/3 removendo o workspace (apaga o state vazio do bucket)"
terraform -chdir="$PARTE1/infra" workspace select default
terraform -chdir="$PARTE1/infra" workspace delete "$WORKSPACE" || true

echo; echo "== 3/3 destroy do bootstrap (bucket de state + tabela de lock)"
terraform -chdir="$PARTE1/bootstrap" destroy -input=false -auto-approve
rm -f "$PARTE1/infra/backend.hcl"

echo; echo "Pronto. Prove: ./verificacao/verifica.sh --pos-destroy"
