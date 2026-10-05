variable "prefixo" {
  description = "Prefixo de todos os recursos (eda262-gNN)."
  type        = string
}

variable "nome_database" {
  description = "Nome do database no Glue Data Catalog (só minúsculas, números e _)."
  type        = string
}

variable "sufixo_bucket" {
  description = "Sufixo dos nomes de bucket (ex.: -<account_id>) ou vazio."
  type        = string
  default     = ""
}

variable "teto_bytes" {
  description = "bytes_scanned_cutoff_per_query do workgroup."
  type        = number
}

variable "dir_dados" {
  description = "Pasta local com dados/raw e dados/trusted gerados por preparar_dados.py."
  type        = string
}

variable "consultas" {
  description = "Named queries a publicar no workgroup: nome => SQL."
  type        = map(string)
  default     = {}
}
