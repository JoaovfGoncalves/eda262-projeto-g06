variable "grupo" {
  description = "Identificador do grupo com dois dígitos (gNN)."
  type        = string
  default     = "g06"

  validation {
    condition     = can(regex("^g[0-9]{2}$", var.grupo))
    error_message = "Use o formato gNN, por exemplo g06."
  }
}

variable "regiao" {
  description = "Região AWS do projeto."
  type        = string
  default     = "us-east-1"
}

variable "teto_bytes" {
  description = <<-EOT
    DECISÃO DE CUSTO: teto de bytes varridos por consulta no workgroup.
    Sai da medição do evidencias/perfil_dados.json (intervalo útil entre o
    varrimento total da trusted e o da raw) e é confirmado no Athena.
  EOT
  type        = number

  validation {
    condition     = var.teto_bytes >= 10485760
    error_message = "O Athena não aceita teto abaixo de 10.485.760 bytes (10 MB). Preencha teto_bytes no terraform.tfvars com o valor medido (veja DECISOES.md)."
  }
}

variable "sufixo_conta_nos_buckets" {
  description = <<-EOT
    Desligado: buckets no padrão exato do guia (eda262-gNN-lake-<camada>).
    Ligue (TF_VAR_sufixo_conta_nos_buckets=true) só se o apply falhar com
    BucketAlreadyExists: acrescenta o ID da conta ao nome dos buckets.
  EOT
  type        = bool
  default     = false
}
