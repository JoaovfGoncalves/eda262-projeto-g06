# ----------------------------------------------------------------------------
# Raiz da Parte 1: só composição. Tudo o que vira recurso está no módulo.
# A raiz decide O QUÊ (grupo, região, teto, quais consultas publicar);
# o módulo decide COMO (buckets, catálogo, workgroup, carga dos dados).
# ----------------------------------------------------------------------------
locals {
  prefixo = "eda262-${var.grupo}"
}

module "lake" {
  source = "./modules/lake"

  prefixo       = local.prefixo
  nome_database = replace("${local.prefixo}_eleicoes", "-", "_")
  sufixo_bucket = var.sufixo_conta_nos_buckets ? "-${data.aws_caller_identity.atual.account_id}" : ""
  teto_bytes    = var.teto_bytes
  dir_dados     = "${path.root}/../dados"

  # A pergunta de negócio fica publicada no Athena como named query,
  # versionada junto com a infraestrutura.
  consultas = {
    "pergunta-votos-validos-por-regiao" = file("${path.root}/../consultas/01_pergunta_votos_validos_por_regiao.sql")
    "presidente-2t-por-regiao-2018-2022" = file("${path.root}/../consultas/02_presidente_2t_por_regiao.sql")
  }
}
