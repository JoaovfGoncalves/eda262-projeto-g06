# ----------------------------------------------------------------------------
# Armazenamento: um bucket por camada + um para resultados do Athena.
# Nomes no padrão eda262-gNN-lake-<camada> do guia (+ sufixo da conta).
# ----------------------------------------------------------------------------
locals {
  buckets = {
    raw        = "${var.prefixo}-lake-raw${var.sufixo_bucket}"
    trusted    = "${var.prefixo}-lake-trusted${var.sufixo_bucket}"
    resultados = "${var.prefixo}-athena-resultados${var.sufixo_bucket}"
  }
}

resource "aws_s3_bucket" "lake" {
  for_each = local.buckets

  bucket = each.value
  # destroy é critério de aceite: sem force_destroy um bucket com objetos
  # não é apagado e vira recurso órfão.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "lake" {
  for_each = aws_s3_bucket.lake

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  for_each = aws_s3_bucket.lake

  bucket = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
