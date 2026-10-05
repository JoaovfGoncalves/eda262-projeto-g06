data "aws_caller_identity" "atual" {}

locals {
  prefixo = "eda262-${var.grupo}"
  # Padrão do guia: eda262-gNN-<recurso>. O sufixo com o ID da conta é a
  # válvula de escape para colisão de nome global (desligado por padrão).
  bucket_tfstate = "${local.prefixo}-tfstate${var.sufixo_conta_nos_buckets ? "-${data.aws_caller_identity.atual.account_id}" : ""}"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_tfstate
  # Sem isto o destroy falha com o bucket cheio de versões do state
  # e o bucket vira recurso órfão.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled" # permite recuperar um state corrompido
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tflock" {
  name         = "${local.prefixo}-tflock"
  billing_mode = "PAY_PER_REQUEST" # custo zero quando ninguém está aplicando
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
