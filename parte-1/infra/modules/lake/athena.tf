# ----------------------------------------------------------------------------
# Athena: workgroup próprio, com configuração imposta e teto de bytes.
# ----------------------------------------------------------------------------
resource "aws_athena_workgroup" "lake" {
  name        = "${var.prefixo}-wg"
  description = "Consultas do lake de eleições (g06). Teto por consulta: ${var.teto_bytes} bytes."
  state       = "ENABLED"
  # Apaga o histórico de consultas e as named queries junto no destroy.
  force_destroy = true

  configuration {
    # Ninguém escapa do teto nem do local de resultados trocando a config no cliente.
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.teto_bytes

    result_configuration {
      output_location = "s3://${aws_s3_bucket.lake["resultados"].id}/resultados/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

resource "aws_athena_named_query" "consultas" {
  for_each = var.consultas

  name        = "${var.prefixo}-${each.key}"
  workgroup   = aws_athena_workgroup.lake.id
  database    = aws_glue_catalog_database.eleicoes.name
  query       = each.value
  description = "Projeto EDA 2026.2 - g06"
}
