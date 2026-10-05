variable "grupo" {
  description = "Identificador do grupo com dois dígitos (gNN)."
  type        = string
  default     = "g06"

  validation {
    condition     = can(regex("^g[0-9]{2}$", var.grupo))
    error_message = "Use o formato gNN, por exemplo g06."
  }
}

variable "sufixo_conta_nos_buckets" {
  description = "Mesma chave da stack infra: acrescenta o ID da conta ao bucket de state. Desligado = padrão do guia."
  type        = bool
  default     = false
}

variable "regiao" {
  description = "Região AWS do projeto."
  type        = string
  default     = "us-east-1"
}
