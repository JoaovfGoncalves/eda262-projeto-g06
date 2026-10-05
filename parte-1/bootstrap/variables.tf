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
