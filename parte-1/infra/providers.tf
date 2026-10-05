provider "aws" {
  region = var.regiao

  # As três tags obrigatórias do guia, em TODO recurso que aceita tag.
  default_tags {
    tags = {
      turma   = "eda262"
      grupo   = var.grupo
      projeto = "engenharia-de-dados"
    }
  }
}

data "aws_caller_identity" "atual" {}
