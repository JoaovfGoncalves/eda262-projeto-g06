# DECISOES.md — grupo g06 · Parte 1 (AV1)

**Cenário.** Resultados das eleições gerais brasileiras de 2018 e 2022, a partir dos dados abertos do TSE (*Votação nominal por município e zona*).

**Pergunta de negócio (descritiva).** Como os votos válidos para Presidente, Governador e Senador se distribuíram em cada região do Brasil (N, NE, CO, SE, S e exterior), no 1º e no 2º turno de 2018 e 2022?

**Como ler este arquivo.** Cada decisão diz o que escolhemos, o número medido que a sustenta e o que aceitamos perder.

> Fontes dos números: saída de `preparar_dados.py` e `evidencias/perfil_dados.json` (preparação dos dados); `evidencias/custos.csv` e `evidencias/resultado_*.tsv` (execuções no Athena em 05/10/2026, via `consultas/executar.sh` e `verifica.sh`).

---

## 1. Grão

**Escolha.** 1 linha da `trusted_votos_validos_zona` = votos válidos de **1 candidato**, em **1 zona eleitoral de 1 município**, em **1 turno**, para **1 cargo**, em **1 eleição (ano)**. A medida é `qt_votos_validos`, aditiva em todas as dimensões.

**Por que zona, e não região nem seção.** A pergunta é por região, mas guardar já agregado por região impediria reconciliar com o TSE e recortar de outro jeito depois (UF, município, mesorregião na Parte 2). Descer até seção eleitoral multiplicaria as linhas sem nenhuma pergunta que precise disso. Zona é o menor grão em que o TSE publica a votação nominal consolidada.

**Números.**
- Linhas na raw (cargos 1, 3 e 5): **414.721** (223.833 em 2018 + 190.888 em 2022).
- Linhas na trusted: **407.921**. As 6.800 linhas de diferença são todas rejeições das regras de limpeza: 1.654 de eleições não gerais (decisão 8) e 5.146 das demais regras, contadas regra a regra no campo `contagens` de `evidencias/perfil_dados.json`.
- Linhas da raw que caíram na mesma chave e precisaram ser somadas: **0** em 2018 e **0** em 2022. O arquivo do TSE já vem nesse grão. A agregação no grão continua no script como proteção: se o TSE voltar a separar voto em trânsito em linhas distintas, a chave continua única.
- Prova de que o grão vale nos dados, no Athena (`04_qualidade_grao.sql`): **407.921 linhas = 407.921 chaves distintas**, com **0** chaves repetidas, **0** linhas com chave nula e **0** votos negativos.

**O que aceitamos perder.** O detalhe por seção eleitoral e por urna.

## 2. Chave

**Escolha.** Chave primária `(ano_eleicao, nr_turno, cd_cargo, sg_uf, cd_municipio, nr_zona, sq_candidato)`, declarada no parâmetro `chave_primaria` da tabela no Glue.

**Por que `sq_candidato` e não `nr_candidato`.** O número de urna se repete: o 40 é candidato a governador em várias UFs, e o 13 existe em 2018 e em 2022. O sequencial do TSE identifica a candidatura. `sg_uf` é redundante com `cd_municipio` (o código TSE do município é nacional), mas fica na chave porque separa o exterior (`ZZ`) de forma explícita e não custa nada.

**Duplicatas de origem.** O ZIP do TSE traz três tipos de arquivo: `_<UF>.csv` com os cargos estaduais, `_BR.csv` com o Presidente de todas as UFs e do exterior, e `_BRASIL.csv` com a junção de tudo. Ler todos somaria cada voto duas vezes. Ler só os arquivos por UF perderia o Presidente inteiro. Foi o que aconteceu na nossa primeira execução: a reconciliação com o TSE não bateu por 57,7 milhões de votos em 2018 e 60,2 milhões em 2022, porque só os votos do exterior tinham entrado. Por isso a cobertura é controlada por fatia (UF × cargo): um arquivo só contribui com fatias que nenhum arquivo anterior trouxe, na ordem UFs → BR → BRASIL.

**Números.**
| | 2018 | 2022 |
|---|---|---|
| Linhas dos arquivos por UF (Governador e Senador) | 130.233 | 109.209 |
| Linhas do Presidente vindas do `_BR.csv` (27 UFs + exterior) | 93.600 | 81.679 |
| Linhas do `_BRASIL.csv` descartadas por duplicarem fatias já cobertas | 223.833 | 190.888 |

A conta fecha exatamente: o `_BRASIL.csv` duplica linha a linha o que veio dos arquivos por UF somado ao `_BR.csv` (130.233 + 93.600 = 223.833; 109.209 + 81.679 = 190.888). Nenhuma fatia UF × cargo ficou sem linha.

- Linhas byte a byte idênticas descartadas: **0** em 2018 e **0** em 2022. Toda a duplicação do TSE estava entre arquivos (o `_BRASIL.csv`), não dentro deles.

**O que aceitamos perder.** Se duas linhas legítimas fossem idênticas em todas as colunas, contaríamos uma só. Aceitamos, porque a reconciliação com o resultado oficial bate voto a voto (seção 6).

## 3. Partição

**Escolha.** Nenhuma tabela é particionada na Parte 1. Particionamento está fora do escopo da AV1.

**Número.** A trusted inteira ocupa **39.389.814 bytes (37,57 MB)**, e a pergunta de negócio lê a tabela inteira (todos os anos, turnos e cargos). Uma partição só ajudaria consultas que filtram um ano ou um cargo, e esse não é o uso desta entrega.

**Sobre a raw.** As pastas `ano_2018/` e `ano_2022/` não são partições. São duas tabelas, uma por eleição, porque o leiaute do TSE é um contrato **por eleição** e a raw é lida **por posição**.

Os dois leiautes têm **50 colunas** e diferem em **2**: as posições 32 e 33 se chamam `CD_SITUACAO_DIPLOMA` e `DS_SITUACAO_DIPLOMA` em 2018, e `CD_SITUACAO_DCONST_DIPLOMA` e `DS_SITUACAO_DCONST_DIPLOMA` em 2022 (comparação dos dois JSONs em `schemas/`). No nosso recorte, essas colunas vêm sem informação nos dois anos (`-3` / `#NE` em todas as 223.833 linhas de 2018 e 190.888 de 2022). As federações **não** são diferença de leiaute: o TSE publica 2018 no leiaute atual, e `NR_FEDERACAO` existe em 2018 com `-1` (sem federação) em todas as 223.833 linhas, porque federação só passou a existir em 2022.

Por que isso sustenta duas tabelas: o `OpenCSVSerde` associa valor a coluna pela posição no arquivo. Numa tabela única com o schema de 2022, as posições 32 e 33 de 2018 seriam lidas com os nomes de 2022, sem nenhum erro. Hoje isso não altera nenhum número, porque as duas colunas estão vazias, mas é exatamente o mecanismo do risco: se o leiaute de 2026 inserir ou remover uma coluna no meio do arquivo, todas as seguintes deslocam e uma eleição inteira passa a ser lida com nomes errados, também sem erro. Com uma tabela por eleição, 2026 entra como tabela nova com o próprio contrato. O custo dessa escolha é que consultar os dois anos na raw exige `UNION ALL`, como na consulta 03.

**O que aceitamos perder.** Toda consulta lê a trusted inteira. Na Parte 2, com Parquet, a partição candidata é `ano_eleicao`/`cd_cargo`, que são os filtros mais comuns em consultas além da pergunta principal.

## 4. Formato

**Escolha.**
- **Raw:** as linhas originais do CSV do TSE, byte a byte (ISO-8859-1, separador `;`, todos os campos entre aspas), só dos cargos 1, 3 e 5, reagrupadas em um arquivo por UF, em **texto puro**. Lida com `OpenCSVSerde`, todas as 50 colunas como `string`: a raw nunca quebra na leitura e não interpreta nada.
- **Trusted:** TSV em UTF-8, em **texto puro**, com 15 colunas tipadas (`int`, `bigint`, `date`, `string`), lida com `LazySimpleSerDe`. TSV porque o `LazySimpleSerDe` não entende aspas e campos do TSE contêm vírgula e ponto e vírgula; o script garante que nenhum valor contém tabulação.

**Por que texto puro e não gzip: a decisão saiu de uma medição.** Na primeira versão gravamos tudo em gzip. Medido, cada camada em gzip ficou abaixo do mínimo de 10 MB que o Athena cobra por consulta:

| Camada | Texto puro (gravado) | Se fosse gzip | Redução do gzip |
|---|---|---|---|
| raw | 185,55 MB | 7,74 MB | 95,8% |
| trusted | 37,57 MB | 2,77 MB | 92,6% |

Com gzip, toda consulta, na raw ou na trusted, pagaria exatamente os mesmos 10 MB. O custo deixaria de distinguir as camadas, e o ganho do Parquet na Parte 2 também ficaria invisível. Texto puro é a linha de base honesta. O gzip continua disponível (`preparar_dados.py --gzip`).

**O que aceitamos perder.** Pagamos mais por consulta do que pagaríamos com gzip. A diferença é de frações de centavo neste volume, e é exatamente o número que a Parte 2 precisa ter para mostrar o ganho do Parquet. O repositório também fica maior em disco (cerca de 223 MB; o maior arquivo, `votacao_candidato_munzona_2018_MG.csv`, tem 15,22 MB), embora o Git comprima os objetos internamente. Na raw, os acentos aparecem quebrados no Athena, porque o arquivo é ISO-8859-1. Isso é sujeira documentada que a trusted corrige.

## 5. Custo

**Escolha.** Workgroup `eda262-g06-wg` com configuração imposta (`enforce_workgroup_configuration = true`) e teto de `bytes_scanned_cutoff_per_query` = **116.391.936 bytes (111 MiB)**.

**De que medição o teto saiu.**
- Varredura completa da trusted (a pergunta de negócio): **39.389.814 bytes** (37,57 MB), medidos nos arquivos gravados.
- Varredura completa da raw: **194.561.331 bytes** (185,55 MB), medidos nos arquivos gravados.
- Intervalo útil: **[39.389.814, 194.561.331)**. Abaixo do piso, a própria pergunta morreria. A partir do topo, a varredura larga da raw passaria e o freio nunca tocaria.
- O teto escolhido, 111 MiB, é o ponto médio do intervalo arredondado para baixo ao MiB. Não é o piso, porque a trusted vai crescer: com a eleição de 2026, deve chegar a cerca de 56 MB e continuará passando com folga. Não é o topo, porque aí a raw passaria; com três eleições, a raw deve chegar a cerca de 280 MB e continuará morrendo no teto.

**Custo medido por consulta no Athena (US$ 5/TB, arredondado ao MB, mínimo 10 MB).**
| Consulta | Workgroup | Estado | Bytes varridos | MB cobrados | US$ | Tempo |
|---|---|---|---|---|---|---|
| 01 pergunta de negócio (trusted) | eda262-g06-wg | SUCCEEDED | 39.389.814 | 38 | 0,00018120 | 879 ms |
| 02 Presidente 2º turno (trusted), versão inicial com JOIN | eda262-g06-wg | SUCCEEDED | 78.779.628 | 76 | 0,00036240 | 976 ms |
| 02 Presidente 2º turno (trusted), versão corrigida | eda262-g06-wg | SUCCEEDED | 39.389.814 | 38 | 0,00018120 | 928 ms |
| 03 mesma pergunta na raw, sem teto | primary | SUCCEEDED | 194.561.331 | 186 | 0,00088692 | 1.586 ms |
| 03 mesma pergunta na raw | eda262-g06-wg | CANCELLED (teto) | 116.391.936 | 111 | 0,00052929 | 1.319 ms |
| 04 prova do grão (trusted) | eda262-g06-wg | SUCCEEDED | 39.389.814 | 38 | 0,00018120 | 995 ms |

Os bytes que o Athena varreu batem exatamente com o tamanho dos arquivos medido na preparação (39.389.814 na trusted, 194.561.331 na raw): a medição local previu o custo sem erro.

**Economia da trusted sobre a raw, confirmada no Athena:** **4,94×** menos bytes (194.561.331 ÷ 39.389.814) e **4,9×** menos custo (US$ 0,00088692 ÷ US$ 0,00018120) para responder a mesma pergunta.

**O teto funcionou como projetado.** A consulta larga na raw foi cancelada com "Bytes scanned limit was exceeded" exatamente em 116.391.936 bytes, e as consultas na trusted passaram.

**Achado da medição: a primeira versão da consulta 02 lia a trusted duas vezes.** Ela varreu 78.779.628 bytes, exatamente 2,0× a tabela. A causa era o `JOIN` de `ranqueado a` com `ranqueado b`: o Athena não materializa a CTE, então cada lado do `JOIN` relia a tabela inteira. Reescrevemos a consulta sem `JOIN`: o 1º e o 2º colocados de cada região saem de uma agregação condicional (`MAX(CASE WHEN pos = 1 …)`) sobre o ranking, com uma única leitura.

| Versão da consulta 02 | Bytes varridos | MB cobrados | US$ |
|---|---|---|---|
| Inicial (JOIN da CTE com ela mesma) | 78.779.628 | 76 | 0,00036240 |
| Corrigida (agregação condicional) | 39.389.814 | 38 | 0,00018120 |

O custo caiu **50%**, e as 12 linhas do resultado ficaram idênticas nas duas versões: mesmos candidatos, percentuais, margens e totais por região. Sem medir o custo de cada consulta, esse custo dobrado teria passado despercebido.

**O que aceitamos perder.**
- Consulta ad hoc na raw pelo workgroup do grupo fica bloqueada. Isso é intencional: quem quer responder a pergunta usa a trusted. A medição da raw usa o workgroup `primary` da conta, que não pertence à stack.
- O teto **não torna gratuita** a consulta que ele mata. O Athena cobra o que foi varrido até o cancelamento: 111 MB, US$ 0,00052929. O teto limita o prejuízo: a mesma consulta sem teto custaria 186 MB, então o teto cortou 40% do custo dela.

---

## Decisões complementares

**6. O que é "voto válido".** São os votos nominais dados a candidatos, sem brancos, nulos e votos anulados (candidatura indeferida ou *sub judice*). Nas duas eleições o leiaute do TSE traz `QT_VOTOS_NOMINAIS_VALIDOS` e `NM_TIPO_DESTINACAO_VOTOS`, então a regra é a mesma: entram só as linhas cuja destinação começa com "Válido", com a quantidade de `QT_VOTOS_NOMINAIS_VALIDOS`. Votos excluídos por destinação não válida: **0** em 2018 e **569.456** em 2022. Prova: os votos válidos do 2º turno para Presidente batem voto a voto com o resultado oficial do TSE, com diferença zero nos quatro números:

| Eleição | Candidato | Trusted | Oficial TSE |
|---|---|---|---|
| 2018 | nº 17 | 57.797.847 | 57.797.847 |
| 2018 | nº 13 | 47.040.906 | 47.040.906 |
| 2022 | nº 13 | 60.345.999 | 60.345.999 |
| 2022 | nº 22 | 58.206.354 | 58.206.354 |

A mesma reconciliação é refeita no Athena pelo critério [5] do `verifica.sh`.

**7. Governador e Senador por partido.** Cada UF tem os próprios candidatos, então somar "candidatos" de estados diferentes numa região não faz sentido. Por isso a pergunta agrega esses cargos por partido. No Senado de 2018 havia duas vagas por UF e cada eleitor votou duas vezes, então os percentuais são de votos, não de eleitores. Brancos e nulos não fazem parte desta tabela.

**8. Eleições não gerais ficam fora da trusted.** O arquivo anual do TSE mistura com a eleição geral as eleições suplementares realizadas no mesmo ano. Linhas com data diferente das quatro datas das eleições gerais ficam na raw e saem da trusted:

| Eleição | Linhas excluídas | Votos excluídos |
|---|---|---|
| 2018 | 1.606 | 1.431.699 |
| 2022 | 48 | 262.849 |

Em 2018, o volume é compatível com a eleição suplementar para governador do Tocantins, realizada em junho daquele ano. Sem esse filtro, os governadores do Tocantins em 2018 teriam votos de duas eleições diferentes somados.

**9. Schema sem Crawler.** A trusted tem cada coluna declarada à mão no HCL, com tipo e comentário. A raw tem as 50 colunas declaradas em `schemas/raw_votacao_candidato_munzona_<ano>.json`, versionado e lido pelo Terraform. Se o TSE mudar o cabeçalho, `preparar_dados.py` **para**: mudar o contrato exige `--aceitar-layout` e revisão no PR. O Crawler mudaria o schema sozinho, de madrugada.

**10. Módulo, backend e workspace.** A raiz só compõe: grupo, região, teto e as consultas publicadas. Tudo o que vira recurso fica no módulo `lake`. O backend (bucket de state versionado + tabela DynamoDB de lock) vive em `parte-1/bootstrap/`, com state local, porque o bucket que guarda o state não pode ser criado pela stack que ele guarda. Ele é o primeiro a subir e o último a cair. O workspace `av1` isola o state desta entrega dentro do backend.

**11. Nome de bucket no padrão exato do guia.** Os buckets se chamam `eda262-g06-lake-raw`, `eda262-g06-lake-trusted`, `eda262-g06-athena-resultados` e `eda262-g06-tfstate`, no padrão `eda262-gNN-<recurso>`, para que o avaliador encontre cada recurso pelo nome previsto. Nome de bucket é global na AWS, então a stack só colidiria se os buckets do grupo ainda existissem quando o avaliador rodasse o `apply`. Isso não acontece: o grupo derruba tudo antes da entrega, e o `verifica.sh --pos-destroy` prova que nenhum bucket `eda262-g06-*` ficou na conta. Como válvula de escape, `sufixo_conta_nos_buckets = true` acrescenta o ID da conta ao nome de todos os buckets, nas duas stacks, se o `apply` falhar com `BucketAlreadyExists`. **O que aceitamos perder:** o nome não é garantidamente único no mundo; o risco foi trocado pela previsibilidade que o guia pede.