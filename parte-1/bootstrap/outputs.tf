output "bucket_tfstate" {
  value = aws_s3_bucket.tfstate.bucket
}

output "tabela_lock" {
  value = aws_dynamodb_table.tflock.name
}

# Conteúdo pronto do infra/backend.hcl (gerado por scripts/deploy.sh).
output "backend_hcl" {
  value = <<-EOT
    bucket         = "${aws_s3_bucket.tfstate.bucket}"
    key            = "parte-1/terraform.tfstate"
    region         = "${var.regiao}"
    dynamodb_table = "${aws_dynamodb_table.tflock.name}"
    encrypt        = true
  EOT
}
