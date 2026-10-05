# Contrato: o verificacao/verifica.sh e os scripts leem estes nomes.
output "bucket_raw" {
  value = module.lake.bucket_raw
}

output "bucket_trusted" {
  value = module.lake.bucket_trusted
}

output "bucket_resultados" {
  value = module.lake.bucket_resultados
}

output "database_name" {
  value = module.lake.database_name
}

output "tabela_trusted" {
  value = module.lake.tabela_trusted
}

output "tabelas_raw" {
  value = module.lake.tabelas_raw
}

output "workgroup_name" {
  value = module.lake.workgroup_name
}

output "teto_bytes" {
  value = module.lake.teto_bytes
}

output "objetos_carregados" {
  value = module.lake.objetos_carregados
}
