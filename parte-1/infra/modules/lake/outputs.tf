output "bucket_raw" {
  value = aws_s3_bucket.lake["raw"].id
}

output "bucket_trusted" {
  value = aws_s3_bucket.lake["trusted"].id
}

output "bucket_resultados" {
  value = aws_s3_bucket.lake["resultados"].id
}

output "database_name" {
  value = aws_glue_catalog_database.eleicoes.name
}

output "tabela_trusted" {
  value = aws_glue_catalog_table.trusted.name
}

output "tabelas_raw" {
  value = [for t in aws_glue_catalog_table.raw : t.name]
}

output "workgroup_name" {
  value = aws_athena_workgroup.lake.name
}

output "teto_bytes" {
  value = aws_athena_workgroup.lake.configuration[0].bytes_scanned_cutoff_per_query
}

output "objetos_carregados" {
  value = {
    raw     = length(aws_s3_object.raw)
    trusted = length(aws_s3_object.trusted)
  }
}
