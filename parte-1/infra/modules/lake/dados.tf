# ----------------------------------------------------------------------------
# Carga dos dados versionados no repositório.
#
# Os arquivos são gerados por parte-1/dados/preparar_dados.py de forma
# determinística (linhas ordenadas; gzip com mtime=0 quando usado): o mesmo
# dado gera o mesmo etag, então um segundo apply não reenvia nada.
# Os padrões aceitam texto puro (.csv/.tsv) e gzip (.csv.gz/.tsv.gz). A chave no S3 espelha o caminho local, e a
# location de cada tabela aponta para o mesmo prefixo (se não bater, o Athena
# devolve zero linhas sem erro).
# ----------------------------------------------------------------------------
locals {
  dir_raw     = "${var.dir_dados}/raw"
  dir_trusted = "${var.dir_dados}/trusted"

  arquivos_raw     = fileset(local.dir_raw, "tse/votacao_candidato_munzona/ano_*/*.csv*")
  arquivos_trusted = fileset(local.dir_trusted, "votos_validos_zona/*.tsv*")
}

resource "aws_s3_object" "raw" {
  for_each = local.arquivos_raw

  bucket       = aws_s3_bucket.lake["raw"].id
  key          = each.value
  source       = "${local.dir_raw}/${each.value}"
  etag         = filemd5("${local.dir_raw}/${each.value}")
  content_type = "text/csv; charset=iso-8859-1"
}

resource "aws_s3_object" "trusted" {
  for_each = local.arquivos_trusted

  bucket       = aws_s3_bucket.lake["trusted"].id
  key          = each.value
  source       = "${local.dir_trusted}/${each.value}"
  etag         = filemd5("${local.dir_trusted}/${each.value}")
  content_type = "text/tab-separated-values; charset=utf-8"
}
