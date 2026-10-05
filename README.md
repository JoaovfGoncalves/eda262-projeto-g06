# eda262-projeto-g06 — Lake de resultados eleitorais

Projeto da disciplina Engenharia de Dados (CESAR School, 2026.2), grupo **g06**.

**Pergunta de negócio (descritiva).** Como os votos válidos para Presidente, Governador e Senador se distribuíram em cada região do Brasil (N, NE, CO, SE, S e exterior), no 1º e no 2º turno das eleições gerais de 2018 e 2022?

**Fonte.** Portal de Dados Abertos do TSE, conjunto *Votação nominal por município e zona* (`votacao_candidato_munzona_<ano>.zip`).

## Arquitetura da Parte 1

```
            preparar_dados.py (local, uma vez; saída versionada no Git)
  ZIP TSE ─────────────────────────────────────────────┐
                                                       ▼
 ┌──────────────────── Terraform · módulo "lake" (workspace av1) ───────────────────┐
 │ S3 eda262-g06-lake-raw               tse/votacao_candidato_munzona/ano_AAAA/*.csv│
 │ S3 eda262-g06-lake-trusted           votos_validos_zona/*.tsv                    │
 │ S3 eda262-g06-athena-resultados                                                  │
 │ Glue DB eda262_g06_eleicoes                                                      │
 │   ├─ raw_votacao_candidato_munzona_2018 / _2022   (schema declarado, strings)    │
 │   └─ trusted_votos_validos_zona                   (15 colunas tipadas, grão)     │
 │ Athena workgroup eda262-g06-wg (teto de bytes, config imposta, named queries)    │
 └──────────────────────────────────────────────────────────────────────────────────┘
 Backend remoto: S3 eda262-g06-tfstate + DynamoDB eda262-g06-tflock (parte-1/bootstrap)
```

Todo recurso leva as tags `turma=eda262`, `grupo=g06`, `projeto=engenharia-de-dados` (via `default_tags`). Nenhum Crawler: os schemas são declarados.

## Estrutura

```
parte-1/
  bootstrap/        backend remoto (S3 + DynamoDB), state local
  infra/            raiz Terraform: backend s3, workspace, módulo, terraform.tfvars
    modules/lake/   buckets, carga dos dados, Glue (schemas), Athena
      schemas/      contrato do cabeçalho da raw por ano (gerado e versionado)
  dados/            preparar_dados.py + raw/ e trusted/ (versionados)
  consultas/        SQL da pergunta, comparação raw x trusted, prova do grão; executar.sh
  scripts/          deploy.sh, destroy.sh
verificacao/        verifica.sh (aceite) + lib_athena.sh
evidencias/         perfil dos dados, custos.csv, resultados, saídas do verifica.sh
DECISOES.md         grão, chave, partição, formato, custo — com números medidos
```

## Pré-requisitos

- Terraform ≥ 1.5, AWS CLI v2, `jq`, Python ≥ 3.9 (só biblioteca padrão), bash.
- Conta AWS com permissão para S3, Glue, Athena e DynamoDB.
- Região **us-east-1**, definida em um só lugar: `parte-1/infra/terraform.tfvars`. Os scripts leem a região desse arquivo e **ignoram** `AWS_REGION`/`AWS_DEFAULT_REGION` do terminal, então não é preciso exportar nada. Todos os comandos saem da **raiz do repositório**.

```bash
aws sts get-caller-identity          # confirme a conta antes de tudo
chmod +x parte-1/scripts/*.sh parte-1/consultas/*.sh verificacao/*.sh
```

## Passo a passo — para o avaliador (dados já no repositório)

```bash
./parte-1/scripts/deploy.sh                  # bootstrap do backend + init + workspace av1 + apply
./verificacao/verifica.sh                    # PASSA/FALHA por critério; grava em evidencias/
./parte-1/scripts/destroy.sh                 # stack, workspace e backend, nessa ordem
./verificacao/verifica.sh --pos-destroy      # prova que nada ficou
```

O `deploy.sh` gera `parte-1/infra/backend.hcl` a partir dos outputs do bootstrap, para que o backend use sempre o nome real do bucket de state. Esse arquivo não vai para o Git.

Os buckets seguem o padrão exato do guia (`eda262-g06-lake-raw`, `eda262-g06-lake-trusted`). Nome de bucket é global na AWS: se o `apply` falhar com `BucketAlreadyExists`, rode `export TF_VAR_sufixo_conta_nos_buckets=true` antes do `deploy.sh`, e o ID da conta é acrescentado ao nome de todos os buckets, inclusive o de state.

## Passo a passo — para o grupo (preparar a entrega)

**1. Gerar os dados (uma vez).** Baixa os ZIPs do TSE (~centenas de MB, não versionados) e grava a raw, a trusted e o schema da raw:

```bash
python3 parte-1/dados/preparar_dados.py
```

Confira a saída. A reconciliação do 2º turno para Presidente precisa dizer **BATE** nos dois anos. O ZIP do TSE tem três tipos de arquivo: `_<UF>.csv` (cargos estaduais), `_BR.csv` (Presidente de todas as UFs e do exterior) e `_BRASIL.csv` (junção de tudo, que duplica os anteriores). O script controla a cobertura por fatia (UF × cargo), então cada voto entra uma vez só. Revise `parte-1/infra/modules/lake/schemas/*.json` e `evidencias/perfil_dados.json`. Se o download falhar, baixe os dois ZIPs manualmente para `parte-1/dados/_download/`.

**2. Decidir o teto.** O script imprime o intervalo útil e uma sugestão. Ponha o valor escolhido em `parte-1/infra/terraform.tfvars` (`teto_bytes`). Com `0` o plan falha de propósito.

**3. Subir e medir.**

```bash
./parte-1/scripts/deploy.sh
./parte-1/consultas/executar.sh parte-1/consultas/01_pergunta_votos_validos_por_regiao.sql
./parte-1/consultas/executar.sh parte-1/consultas/02_presidente_2t_por_regiao.sql
./parte-1/consultas/executar.sh parte-1/consultas/03_mesma_pergunta_na_raw.sql --sem-teto
./parte-1/consultas/executar.sh parte-1/consultas/03_mesma_pergunta_na_raw.sql   # deve morrer no teto
./parte-1/consultas/executar.sh parte-1/consultas/04_qualidade_grao.sql
```

Cada execução imprime bytes varridos, MB cobrados e custo em US$, e acrescenta uma linha em `evidencias/custos.csv`.

**4. Fechar o `DECISOES.md`.** Substitua cada `«MEDIR: …»` pelo número medido.

**5. Verificar, derrubar, provar e entregar.**

```bash
./verificacao/verifica.sh
./parte-1/scripts/destroy.sh
./verificacao/verifica.sh --pos-destroy
git add -A && git commit -m "Parte 1 (AV1)" && git tag av1-entrega && git push origin main --tags
```

Derrube tudo na conta do grupo **antes** de o avaliador rodar, para não haver custo residual.

## Custos esperados

Com os volumes da Parte 1, cada consulta custa frações de centavo (mínimo cobrado: 10 MB = US$ 0,0000477). S3 e DynamoDB sob demanda ficam em centavos por mês enquanto a stack estiver de pé.

## Observações

- A partir do Terraform 1.11, o parâmetro `dynamodb_table` do backend S3 gera um aviso de depreciação (o recomendado passou a ser `use_lockfile`). O guia exige DynamoDB, então o aviso é esperado e não afeta o funcionamento.
- O `.terraform.lock.hcl` gerado no primeiro `init` deve ser versionado, para fixar as versões do provider.