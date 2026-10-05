# ----------------------------------------------------------------------------
# BOOTSTRAP do backend remoto (S3 + DynamoDB).
#
# Esta pasta resolve o "ovo e a galinha": o bucket que guarda o state da stack
# principal não pode ser criado pela própria stack principal. Por isso ela tem
# state LOCAL (bootstrap/terraform.tfstate, fora do Git) e é a primeira a subir
# e a última a cair (scripts/deploy.sh e scripts/destroy.sh garantem a ordem).
# ----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 7.0"
    }
  }
}

provider "aws" {
  region = var.regiao

  default_tags {
    tags = {
      turma   = "eda262"
      grupo   = var.grupo
      projeto = "engenharia-de-dados"
    }
  }
}
