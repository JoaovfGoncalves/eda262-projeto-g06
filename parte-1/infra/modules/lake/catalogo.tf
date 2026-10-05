# ----------------------------------------------------------------------------
# Catálogo: schema DECLARADO, nenhum Crawler.
# ----------------------------------------------------------------------------
resource "aws_glue_catalog_database" "eleicoes" {
  name        = var.nome_database
  description = "Resultados das eleições gerais 2018 e 2022 (TSE) - projeto EDA 2026.2"
}

# ---------------------------------------------------------------------------
# RAW: uma tabela por ano, porque o TSE muda o leiaute entre eleições
# (2022 trouxe federações e votos válidos explícitos). As colunas vêm do
# contrato schemas/raw_votacao_candidato_munzona_<ano>.json, versionado e
# revisado em PR; se o TSE mudar o cabeçalho, preparar_dados.py PARA em vez
# de aceitar sozinho. Todas as colunas são string: a raw nunca falha na
# leitura e não interpreta nada (o "17,82" do Exercício 01 não derruba nada aqui).
# ---------------------------------------------------------------------------
locals {
  schemas_raw = {
    for f in fileset("${path.module}/schemas", "raw_votacao_candidato_munzona_*.json") :
    regex("([0-9]{4})\\.json$", f)[0] => jsondecode(file("${path.module}/schemas/${f}"))
  }
}

resource "aws_glue_catalog_table" "raw" {
  for_each = local.schemas_raw

  name          = "raw_votacao_candidato_munzona_${each.key}"
  database_name = aws_glue_catalog_database.eleicoes.name
  table_type    = "EXTERNAL_TABLE"
  description   = "RAW: recorte fiel do arquivo do TSE (${each.value.encoding}, separador ';'), só cargos 1, 3 e 5."

  parameters = {
    "classification"         = "csv"
    "skip.header.line.count" = "1"
    "camada"                 = "raw"
    "fonte"                  = each.value.origem
    "encoding_origem"        = each.value.encoding
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.lake["raw"].id}/tse/votacao_candidato_munzona/ano_${each.key}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "opencsv"
      serialization_library = "org.apache.hadoop.hive.serde2.OpenCSVSerde"
      parameters = {
        "separatorChar" = ";"
        "quoteChar"     = "\""
        "escapeChar"    = "\\"
      }
    }

    dynamic "columns" {
      for_each = each.value.colunas
      content {
        name = lower(columns.value)
        type = "string"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# TRUSTED: tabela modelada, tipada, com grão e chave declarados.
# Formato: TSV UTF-8 em texto puro (Parquet é escopo da Parte 2).
# O Athena detecta gzip pela extensão, se um dia os arquivos forem .gz.
# ---------------------------------------------------------------------------
resource "aws_glue_catalog_table" "trusted" {
  name          = "trusted_votos_validos_zona"
  database_name = aws_glue_catalog_database.eleicoes.name
  table_type    = "EXTERNAL_TABLE"
  description   = "TRUSTED: votos válidos por candidato e zona eleitoral, Presidente/Governador/Senador, 2018 e 2022, 1º e 2º turnos."

  parameters = {
    "classification"         = "csv"
    "skip.header.line.count" = "1"
    "camada"                 = "trusted"
    "grao"                   = "1 linha = votos válidos de 1 candidato, em 1 zona eleitoral de 1 município, em 1 turno, para 1 cargo, em 1 eleição (ano)"
    "chave_primaria"         = "ano_eleicao,nr_turno,cd_cargo,sg_uf,cd_municipio,nr_zona,sq_candidato"
    "medida"                 = "qt_votos_validos (aditiva em todas as dimensões)"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.lake["trusted"].id}/votos_validos_zona/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "tsv"
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"
      parameters = {
        "field.delim"          = "\t"
        "serialization.format" = "\t"
      }
    }

    columns {
      name    = "ano_eleicao"
      type    = "int"
      comment = "Chave. Ano da eleição geral (2018 ou 2022)."
    }
    columns {
      name    = "nr_turno"
      type    = "int"
      comment = "Chave. 1 ou 2."
    }
    columns {
      name    = "dt_eleicao"
      type    = "date"
      comment = "Data do turno da eleição geral (eleições suplementares ficam de fora)."
    }
    columns {
      name    = "cd_cargo"
      type    = "int"
      comment = "Chave. 1 = Presidente, 3 = Governador, 5 = Senador."
    }
    columns {
      name    = "ds_cargo"
      type    = "string"
      comment = "PRESIDENTE | GOVERNADOR | SENADOR (normalizado a partir de cd_cargo)."
    }
    columns {
      name    = "regiao"
      type    = "string"
      comment = "N | NE | CO | SE | S | EX (exterior). Derivada de sg_uf."
    }
    columns {
      name    = "sg_uf"
      type    = "string"
      comment = "Chave. UF da zona; ZZ = exterior."
    }
    columns {
      name    = "cd_municipio"
      type    = "int"
      comment = "Chave. Código TSE do município."
    }
    columns {
      name    = "nm_municipio"
      type    = "string"
      comment = "Nome do município (UTF-8)."
    }
    columns {
      name    = "nr_zona"
      type    = "int"
      comment = "Chave. Número da zona eleitoral."
    }
    columns {
      name    = "sq_candidato"
      type    = "bigint"
      comment = "Chave. Sequencial do candidato no TSE (estável dentro da eleição)."
    }
    columns {
      name    = "nr_candidato"
      type    = "int"
      comment = "Número de urna (não é chave: repete entre UFs e anos)."
    }
    columns {
      name    = "nm_urna_candidato"
      type    = "string"
      comment = "Nome de urna."
    }
    columns {
      name    = "sg_partido"
      type    = "string"
      comment = "Sigla do partido; nulo quando o TSE manda #NE#/#NULO#."
    }
    columns {
      name    = "qt_votos_validos"
      type    = "bigint"
      comment = "Medida. Votos nominais válidos (sem brancos, nulos e anulados)."
    }
  }
}
