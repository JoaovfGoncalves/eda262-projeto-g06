terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 7.0"
    }
  }

  # Backend remoto com trava. Bucket, chave, região e tabela vêm do
  # backend.hcl, gerado pelo bootstrap (o nome do bucket depende da conta).
  # Cada workspace grava em <workspace_key_prefix>/<workspace>/<key>.
  backend "s3" {
    workspace_key_prefix = "eda262-g06"
  }
}
