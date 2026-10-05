#!/usr/bin/env python3
"""
Prepara as camadas RAW e TRUSTED do lake a partir dos arquivos oficiais do TSE
("Votação nominal por município e zona"), para 2018 e 2022.

  RAW     = recorte FIEL do arquivo do TSE: mesmas linhas, mesmos bytes, mesmo
            encoding (ISO-8859-1), mesmo separador. Só ficam as linhas dos cargos
            da pergunta (Presidente, Governador, Senador). Nada é corrigido.
  TRUSTED = votos válidos, limpos, tipados, deduplicados, com a região.
            Grão: 1 linha = votos válidos de 1 candidato, em 1 zona eleitoral
            de 1 município, em 1 turno, para 1 cargo, em 1 eleição (ano).

Uso:
  python3 preparar_dados.py                  # baixa (se preciso) e prepara 2018 e 2022
  python3 preparar_dados.py --anos 2022      # só um ano
  python3 preparar_dados.py --aceitar-layout # aceita um cabeçalho novo do TSE e regrava o schema

Só usa a biblioteca padrão do Python 3.9+. A saída é determinística (gzip com
mtime=0 e linhas ordenadas): rodar de novo com a mesma entrada gera os mesmos
bytes, então o Terraform não vê mudança nos objetos do S3.
"""
from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import json
import sys
import urllib.request
import zipfile
import zlib
from collections import Counter, defaultdict
from pathlib import Path

# --------------------------------------------------------------------------- #
# Constantes do domínio
# --------------------------------------------------------------------------- #
URL_TSE = ("https://cdn.tse.jus.br/estatistica/sead/odsele/"
           "votacao_candidato_munzona/votacao_candidato_munzona_{ano}.zip")

# Datas das eleições GERAIS. Linhas com outra data (ex.: eleição suplementar
# para governador do Tocantins em junho/2018) ficam na raw e saem da trusted.
DATAS_GERAIS = {
    2018: {1: "2018-10-07", 2: "2018-10-28"},
    2022: {1: "2022-10-02", 2: "2022-10-30"},
}

CARGOS = {1: "PRESIDENTE", 3: "GOVERNADOR", 5: "SENADOR"}

REGIAO_POR_UF = {
    "AC": "N", "AM": "N", "AP": "N", "PA": "N", "RO": "N", "RR": "N", "TO": "N",
    "AL": "NE", "BA": "NE", "CE": "NE", "MA": "NE", "PB": "NE", "PE": "NE",
    "PI": "NE", "RN": "NE", "SE": "NE",
    "DF": "CO", "GO": "CO", "MS": "CO", "MT": "CO",
    "ES": "SE", "MG": "SE", "RJ": "SE", "SP": "SE",
    "PR": "S", "RS": "S", "SC": "S",
    "ZZ": "EX",  # votos no exterior (só existem para Presidente)
}
UFS_VALIDAS = set(REGIAO_POR_UF)
ARQUIVOS_NACIONAIS = {"BR", "BRASIL"}  # duplicam o conteúdo dos arquivos por UF

# Valores-sentinela que o TSE usa para "não se aplica"/"não informado".
SENTINELAS = {"", "#NULO#", "#NULO", "#NE#", "#NE", "-1", "-3"}

# Resultado oficial do 2º turno para Presidente (votos válidos por número).
# Usado como teste de reconciliação: a trusted precisa bater voto a voto.
OFICIAL_PRESIDENTE_2T = {
    2018: {17: 57_797_847, 13: 47_040_906},
    2022: {13: 60_345_999, 22: 58_206_354},
}

COLUNAS_TRUSTED = [
    "ano_eleicao", "nr_turno", "dt_eleicao", "cd_cargo", "ds_cargo", "regiao",
    "sg_uf", "cd_municipio", "nm_municipio", "nr_zona", "sq_candidato",
    "nr_candidato", "nm_urna_candidato", "sg_partido", "qt_votos_validos",
]
NULO_TRUSTED = "\\N"  # marcador de nulo padrão do LazySimpleSerDe

AQUI = Path(__file__).resolve().parent
RAIZ_REPO = AQUI.parent.parent
DIR_DOWNLOAD = AQUI / "_download"
DIR_RAW = AQUI / "raw" / "tse" / "votacao_candidato_munzona"
DIR_TRUSTED = AQUI / "trusted" / "votos_validos_zona"
DIR_SCHEMAS = AQUI.parent / "infra" / "modules" / "lake" / "schemas"
ARQ_PERFIL = RAIZ_REPO / "evidencias" / "perfil_dados.json"

TETO_MINIMO_ATHENA = 10 * 1024 * 1024  # 10.485.760 bytes


# --------------------------------------------------------------------------- #
# Utilidades
# --------------------------------------------------------------------------- #
USAR_GZIP = False  # definido por --gzip


class Saida:
    """Grava um arquivo em texto puro (padrão) ou em gzip determinístico (mtime=0),
    e mede SEMPRE os dois tamanhos: o gravado e o que o arquivo teria em gzip.
    O segundo número é a evidência da decisão de formato no DECISOES.md."""

    def __init__(self, caminho_sem_gz: Path):
        caminho_sem_gz.parent.mkdir(parents=True, exist_ok=True)
        self.caminho = caminho_sem_gz.with_name(caminho_sem_gz.name + (".gz" if USAR_GZIP else ""))
        self._bruto = open(self.caminho, "wb")
        self._gz = (gzip.GzipFile(filename="", mode="wb", fileobj=self._bruto, mtime=0, compresslevel=9)
                    if USAR_GZIP else None)
        self._medidor = zlib.compressobj(9, zlib.DEFLATED, 31)  # 31 = formato gzip
        self.bytes_texto = 0
        self.bytes_gzip = 0

    def write(self, dados: bytes) -> None:
        (self._gz or self._bruto).write(dados)
        self.bytes_texto += len(dados)
        self.bytes_gzip += len(self._medidor.compress(dados))

    def close(self) -> None:
        self.bytes_gzip += len(self._medidor.flush())
        if self._gz:
            self._gz.close()
        self._bruto.close()


def limpar(valor: str | None) -> str | None:
    if valor is None:
        return None
    v = valor.strip()
    return None if v.upper() in SENTINELAS else v


def para_int(valor: str | None) -> int | None:
    v = limpar(valor)
    if v is None:
        return None
    try:
        return int(v)
    except ValueError:
        return None


def baixar(ano: int) -> Path:
    destino = DIR_DOWNLOAD / f"votacao_candidato_munzona_{ano}.zip"
    if destino.exists() and destino.stat().st_size > 0:
        print(f"  [ok] {destino.name} já baixado ({destino.stat().st_size/1e6:.1f} MB)")
        return destino
    DIR_DOWNLOAD.mkdir(parents=True, exist_ok=True)
    url = URL_TSE.format(ano=ano)
    print(f"  baixando {url}")
    tmp = destino.with_suffix(".parcial")
    try:
        with urllib.request.urlopen(url, timeout=120) as resp, open(tmp, "wb") as out:
            while True:
                bloco = resp.read(1 << 20)
                if not bloco:
                    break
                out.write(bloco)
    except Exception as erro:  # noqa: BLE001
        tmp.unlink(missing_ok=True)
        sys.exit(f"\nFalha no download ({erro}).\nBaixe manualmente {url}\n"
                 f"e salve como {destino}")
    tmp.rename(destino)
    print(f"  [ok] {destino.stat().st_size/1e6:.1f} MB")
    return destino


def sufixo_uf(nome_membro: str) -> str | None:
    """votacao_candidato_munzona_2022_PE.csv -> 'PE'."""
    nome = Path(nome_membro).name
    if not nome.lower().endswith(".csv"):
        return None
    return nome[:-4].rsplit("_", 1)[-1].upper()


# --------------------------------------------------------------------------- #
# Schema da raw: contrato com o cabeçalho do TSE
# --------------------------------------------------------------------------- #
def conferir_schema(ano: int, cabecalho: list[str], aceitar: bool) -> None:
    """O schema da raw é declarado em JSON versionado e lido pelo Terraform.
    Se o TSE mudar o cabeçalho, o script PARA: mudar o contrato exige uma ação
    humana explícita (--aceitar-layout) e passa por revisão no PR."""
    DIR_SCHEMAS.mkdir(parents=True, exist_ok=True)
    arq = DIR_SCHEMAS / f"raw_votacao_candidato_munzona_{ano}.json"
    novo = {
        "ano": ano,
        "origem": URL_TSE.format(ano=ano),
        "encoding": "ISO-8859-1",
        "separador": ";",
        "colunas": cabecalho,
    }
    if arq.exists():
        atual = json.loads(arq.read_text(encoding="utf-8"))
        if atual.get("colunas") == cabecalho:
            return
        if not aceitar:
            antigas, novas = set(atual.get("colunas", [])), set(cabecalho)
            sys.exit(
                f"\n[PARE] O cabeçalho do TSE para {ano} difere do schema declarado em\n"
                f"  {arq.relative_to(RAIZ_REPO)}\n"
                f"  colunas só no schema : {sorted(antigas - novas)}\n"
                f"  colunas só no arquivo: {sorted(novas - antigas)}\n"
                f"Revise e, se estiver certo, rode de novo com --aceitar-layout."
            )
        print(f"  [!] schema raw {ano} REGRAVADO por --aceitar-layout")
    else:
        print(f"  [+] schema raw {ano} declarado em {arq.relative_to(RAIZ_REPO)} "
              f"({len(cabecalho)} colunas) — revise e versione no Git")
    arq.write_text(json.dumps(novo, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


# --------------------------------------------------------------------------- #
# Processamento de um ano
# --------------------------------------------------------------------------- #
def processar_ano(ano: int, zip_path: Path, aceitar_layout: bool) -> dict:
    """Uma passada só, em streaming: cada linha vai para a raw (bytes originais)
    e, se sobreviver às regras, é agregada no grão da trusted."""
    perfil = Counter()
    votos_excluidos = Counter()
    estado: dict = {"cab_bytes": None, "cab": None, "idx": None}
    hashes_vistos: set[bytes] = set()
    escritores_raw: dict[str, Saida] = {}
    agregado: dict[tuple, list] = {}
    datas_validas = {f"{d[8:10]}/{d[5:7]}/{d[0:4]}": t for t, d in DATAS_GERAIS[ano].items()}

    dir_raw_ano = DIR_RAW / f"ano_{ano}"
    dir_raw_ano.mkdir(parents=True, exist_ok=True)
    for antigo in [*dir_raw_ano.glob("*.csv"), *dir_raw_ano.glob("*.csv.gz")]:
        antigo.unlink()

    def escrever_raw(uf: str, linha: bytes) -> None:
        if uf not in escritores_raw:
            escritores_raw[uf] = Saida(dir_raw_ano / f"votacao_candidato_munzona_{ano}_{uf}.csv")
            escritores_raw[uf].write(estado["cab_bytes"])
        escritores_raw[uf].write(linha)

    # ---- regras da trusted ------------------------------------------------ #
    def regras():
        idx = estado["idx"]
        tem = idx.__contains__
        col_votos = "QT_VOTOS_NOMINAIS_VALIDOS" if tem("QT_VOTOS_NOMINAIS_VALIDOS") else "QT_VOTOS_NOMINAIS"
        if tem("NM_TIPO_DESTINACAO_VOTOS"):
            regra = "NM_TIPO_DESTINACAO_VOTOS começa com 'Válido'"
        elif tem("DS_SITUACAO_CANDIDATURA"):
            regra = "DS_SITUACAO_CANDIDATURA = 'APTO'"
        else:
            regra = "nenhuma coluna de validade no leiaute: todos os votos nominais"
        return tem, col_votos, regra

    def agregar(uf: str, campos: list[str]) -> None:
        idx = estado["idx"]
        tem, col_votos, _ = estado["regras"]

        def get(nome):
            return campos[idx[nome]] if tem(nome) else None

        votos = para_int(get(col_votos))
        bruto = para_int(get("QT_VOTOS_NOMINAIS"))
        if votos is None or votos < 0:
            perfil["rejeitadas_votos_invalidos_ou_sentinela"] += 1
            return
        if para_int(get("ANO_ELEICAO")) != ano:
            perfil["rejeitadas_ano_divergente"] += 1
            return
        if (get("DT_ELEICAO") or "").strip() not in datas_validas:
            perfil["rejeitadas_eleicao_nao_geral_ex_suplementar"] += 1
            votos_excluidos["eleicao_nao_geral"] += bruto or 0
            return
        turno = para_int(get("NR_TURNO"))
        if turno not in DATAS_GERAIS[ano]:
            perfil["rejeitadas_turno_invalido"] += 1
            return
        if uf not in REGIAO_POR_UF:
            perfil["rejeitadas_uf_desconhecida"] += 1
            return
        if tem("NM_TIPO_DESTINACAO_VOTOS"):
            d = (limpar(get("NM_TIPO_DESTINACAO_VOTOS")) or "").upper()
            valido = d.startswith("VÁLIDO") or d.startswith("VALIDO")
        elif tem("DS_SITUACAO_CANDIDATURA"):
            valido = (limpar(get("DS_SITUACAO_CANDIDATURA")) or "").upper() == "APTO"
        else:
            valido = True
        if not valido:
            perfil["rejeitadas_voto_nao_valido"] += 1
            votos_excluidos["destinacao_nao_valida"] += bruto or 0
            return
        if bruto is not None and votos != bruto:
            votos_excluidos["diferenca_nominal_vs_valido"] += bruto - votos

        cd_mun, zona, sq = para_int(get("CD_MUNICIPIO")), para_int(get("NR_ZONA")), para_int(get("SQ_CANDIDATO"))
        if None in (cd_mun, zona, sq):
            perfil["rejeitadas_chave_nula"] += 1
            return
        chave = (ano, turno, para_int(get("CD_CARGO")), uf, cd_mun, zona, sq)
        attrs = (limpar(get("NM_MUNICIPIO")), para_int(get("NR_CANDIDATO")),
                 limpar(get("NM_URNA_CANDIDATO")), limpar(get("SG_PARTIDO")))
        perfil["atributos_nulos_por_sentinela"] += sum(a is None for a in attrs)
        if chave in agregado:
            perfil["linhas_somadas_no_grao_ex_voto_em_transito"] += 1
            agregado[chave][0] += votos
            if agregado[chave][1] != attrs:
                perfil["conflitos_de_atributo_no_grao"] += 1
        else:
            agregado[chave] = [votos, attrs]

    # ---- leitura do ZIP --------------------------------------------------- #
    with zipfile.ZipFile(zip_path) as zf:
        membros = [m for m in zf.namelist() if sufixo_uf(m)]
        por_uf = {sufixo_uf(m): m for m in membros if sufixo_uf(m) in UFS_VALIDAS}
        nacionais = [m for m in membros if sufixo_uf(m) in ARQUIVOS_NACIONAIS]
        ignorados = [m for m in membros if sufixo_uf(m) not in UFS_VALIDAS | ARQUIVOS_NACIONAIS]
        if ignorados:
            print(f"  [!] membros ignorados (UF desconhecida): {ignorados}")
        print(f"  {len(por_uf)} arquivos por UF, {len(nacionais)} nacionais "
              f"({', '.join(Path(n).name for n in nacionais) or '-'})")

        def ler_membro(nome_membro: str):
            """Itera (uf, bytes_originais, campos) só das linhas dos cargos da pergunta."""
            with zf.open(nome_membro) as f:
                cab = f.readline()
                texto_cab = cab.decode("latin-1").rstrip("\r\n")
                if texto_cab.startswith("\u00ef\u00bb\u00bf"):  # BOM UTF-8 lido como latin-1
                    texto_cab = texto_cab[3:]
                campos_cab = [c.strip() for c in next(csv.reader([texto_cab], delimiter=";", quotechar='"'))]
                if estado["cab"] is None:
                    conferir_schema(ano, campos_cab, aceitar_layout)  # pode parar aqui
                    estado.update(cab_bytes=cab, cab=campos_cab,
                                  idx={n: i for i, n in enumerate(campos_cab)})
                    estado["regras"] = regras()
                    print(f"  votos: {estado['regras'][1]} | validade: {estado['regras'][2]}")
                elif campos_cab != estado["cab"]:
                    sys.exit(f"[PARE] cabeçalho de {nome_membro} difere dos demais arquivos de {ano}")
                i_cargo, i_uf = campos_cab.index("CD_CARGO"), campos_cab.index("SG_UF")
                for linha in f:
                    if not linha.strip():
                        continue
                    perfil["linhas_lidas_tse"] += 1
                    campos = next(csv.reader([linha.decode("latin-1").rstrip("\r\n")], delimiter=";", quotechar='"'))
                    if len(campos) != len(campos_cab):
                        perfil["linhas_malformadas"] += 1
                        continue
                    if para_int(campos[i_cargo]) not in CARGOS:
                        continue
                    if not linha.endswith(b"\n"):
                        linha += b"\r\n"
                    yield campos[i_uf].strip().upper(), linha, campos

        def aceitar(uf: str, linha: bytes, campos: list[str]) -> None:
            # a raw guarda tudo o que entra (inclusive a duplicata): a sujeira fica visível lá
            escrever_raw(uf, linha)
            # a trusted descarta a linha byte a byte idêntica a uma já vista
            h = hashlib.blake2b(linha, digest_size=16).digest()
            if h in hashes_vistos:
                perfil["linhas_duplicadas_identicas"] += 1
                return
            hashes_vistos.add(h)
            agregar(uf, campos)

        # Estrutura real do ZIP do TSE:
        #   _<UF>.csv   -> cargos estaduais da UF (Governador, Senador, Deputados)
        #   _BR.csv     -> Presidente, de todas as UFs e do exterior (ZZ)
        #   _BRASIL.csv -> junção de tudo (duplica os anteriores)
        # A cobertura é controlada por FATIA (UF, cargo): um arquivo só contribui
        # com fatias que nenhum arquivo anterior trouxe. Ordem: UFs, BR, BRASIL.
        cobertas: set[tuple] = set()
        ordem = [(m, False) for _, m in sorted(por_uf.items())]
        ordem += [(m, True) for m in sorted(nacionais, key=lambda n: (len(sufixo_uf(n)), n))]
        for membro, nacional in ordem:
            novas: Counter = Counter()
            ignoradas = 0
            for uf, linha, campos in ler_membro(membro):
                perfil["linhas_cargos_pergunta"] += 1
                fatia = (uf, para_int(campos[estado["idx"]["CD_CARGO"]]))
                if fatia in cobertas:
                    ignoradas += 1
                    continue
                novas[fatia] += 1
                aceitar(uf, linha, campos)
            cobertas.update(novas)
            if nacional:
                perfil["linhas_nacional_duplicadas_ignoradas"] += ignoradas
                perfil["linhas_completadas_pelo_nacional"] += sum(novas.values())
                por_cargo = Counter()
                for (_, cargo), n in novas.items():
                    por_cargo[CARGOS.get(cargo, cargo)] += n
                ufs = sorted({uf for uf, _ in novas})
                print(f"  {Path(membro).name}: +{sum(novas.values()):,} linhas novas "
                      f"{dict(por_cargo) or ''} em {len(ufs)} UFs; {ignoradas:,} ignoradas (fatia já coberta)")
            elif ignoradas:
                perfil["linhas_uf_ignoradas_fatia_ja_coberta"] += ignoradas

        faltando = sorted(f"{uf}/{CARGOS[c]}" for uf in REGIAO_POR_UF for c in (1, 3, 5)
                          if (uf, c) not in cobertas and not (uf == "ZZ" and c != 1))
        if faltando:
            print(f"  [!] fatias (UF/cargo) sem nenhuma linha: {faltando}")

    for saida in escritores_raw.values():
        saida.close()
    if estado["cab"] is None:
        sys.exit(f"[PARE] nenhum CSV reconhecido em {zip_path}")

    # ---- grava a trusted por UF, ordenada pela chave ----------------------- #
    DIR_TRUSTED.mkdir(parents=True, exist_ok=True)
    for antigo in DIR_TRUSTED.glob(f"votos_validos_zona_{ano}_*.tsv*"):
        antigo.unlink()
    por_uf_tr: dict[str, list] = defaultdict(list)
    for chave, (votos, attrs) in agregado.items():
        por_uf_tr[chave[3]].append((chave, votos, attrs))

    def fmt(v) -> str:
        if v is None:
            return NULO_TRUSTED
        return str(v).replace("\t", " ").replace("\n", " ").replace("\r", " ")

    cab_tr = ("\t".join(COLUNAS_TRUSTED) + "\n").encode("utf-8")
    bytes_tr = bytes_tr_gz = 0
    totais_pres_2t = Counter()
    for uf, regs in sorted(por_uf_tr.items()):
        regs.sort(key=lambda r: r[0])
        def linhas(regs=regs):
            yield cab_tr
            for (a, t, cargo, sg_uf, cd_mun, zona, sq), votos, (nm_mun, nr_cand, nm_urna, partido) in regs:
                if cargo == 1 and t == 2:
                    totais_pres_2t[nr_cand] += votos
                reg = [a, t, DATAS_GERAIS[a][t], cargo, CARGOS[cargo], REGIAO_POR_UF[sg_uf],
                       sg_uf, cd_mun, nm_mun, zona, sq, nr_cand, nm_urna, partido, votos]
                yield ("\t".join(fmt(v) for v in reg) + "\n").encode("utf-8")
        saida = Saida(DIR_TRUSTED / f"votos_validos_zona_{ano}_{uf}.tsv")
        for b in linhas():
            saida.write(b)
        saida.close()
        bytes_tr += saida.bytes_texto
        bytes_tr_gz += saida.bytes_gzip

    oficial = OFICIAL_PRESIDENTE_2T.get(ano, {})
    reconciliacao = {
        str(nr): {"trusted": totais_pres_2t.get(nr, 0), "oficial": v,
                  "diferenca": totais_pres_2t.get(nr, 0) - v}
        for nr, v in oficial.items()
    }
    ok = all(r["diferenca"] == 0 for r in reconciliacao.values())
    print(f"  reconciliação Presidente 2º turno {ano}: {'BATE' if ok else 'NÃO BATE'}")
    for nr, r in reconciliacao.items():
        print(f"    nº {nr}: trusted {r['trusted']:,} | oficial {r['oficial']:,} | dif {r['diferenca']:+,}")

    sha = hashlib.sha256()
    with open(zip_path, "rb") as f:
        for bloco in iter(lambda: f.read(1 << 20), b""):
            sha.update(bloco)

    return {
        "ano": ano,
        "zip": zip_path.name,
        "zip_sha256": sha.hexdigest(),
        "colunas_raw": len(estado["cab"]),
        "coluna_votos": estado["regras"][1],
        "regra_validade": estado["regras"][2],
        "contagens": dict(perfil),
        "votos_excluidos": dict(votos_excluidos),
        "linhas_trusted": len(agregado),
        "bytes_raw_texto": sum(s.bytes_texto for s in escritores_raw.values()),
        "bytes_raw_se_gzip": sum(s.bytes_gzip for s in escritores_raw.values()),
        "bytes_trusted_texto": bytes_tr,
        "bytes_trusted_se_gzip": bytes_tr_gz,
        "reconciliacao_presidente_2t": reconciliacao,
        "reconciliacao_ok": ok,
    }


def tamanho(pasta: Path, padrao: str) -> int:
    """Soma o tamanho dos arquivos gravados = bytes que o Athena varre numa leitura completa."""
    return sum(p.stat().st_size for p in pasta.rglob(padrao))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--anos", nargs="+", type=int, default=[2018, 2022], choices=[2018, 2022])
    ap.add_argument("--zip-dir", type=Path, default=DIR_DOWNLOAD,
                    help="pasta com votacao_candidato_munzona_<ano>.zip (baixa se faltar)")
    ap.add_argument("--aceitar-layout", action="store_true",
                    help="regrava o schema raw se o cabeçalho do TSE mudou")
    ap.add_argument("--gzip", action="store_true",
                    help="grava em gzip (padrão: texto puro; ver DECISOES.md, Formato)")
    args = ap.parse_args()
    global USAR_GZIP
    USAR_GZIP = args.gzip

    resultados = []
    for ano in args.anos:
        print(f"\n=== {ano} ===")
        zip_path = args.zip_dir / f"votacao_candidato_munzona_{ano}.zip"
        if not zip_path.exists():
            zip_path = baixar(ano)
        resultados.append(processar_ano(ano, zip_path, args.aceitar_layout))

    raw_arq = tamanho(AQUI / "raw", "*.csv*")
    tr_arq = tamanho(AQUI / "trusted", "*.tsv*")
    raw_txt = sum(r["bytes_raw_texto"] for r in resultados)
    tr_txt = sum(r["bytes_trusted_texto"] for r in resultados)
    raw_gzm = sum(r["bytes_raw_se_gzip"] for r in resultados)
    tr_gzm = sum(r["bytes_trusted_se_gzip"] for r in resultados)

    # Sugestão de teto: entre a varredura completa da trusted e a da raw.
    # A consulta de negócio (trusted) passa; a varredura larga da raw morre.
    teto = None
    piso = max(tr_arq, TETO_MINIMO_ATHENA)
    if raw_arq > piso:
        teto = max(TETO_MINIMO_ATHENA, (((piso + raw_arq) // 2) // (1 << 20)) * (1 << 20))

    perfil = {
        "gerado_por": "parte-1/dados/preparar_dados.py",
        "anos": resultados,
        "lake": {
            "formato_gravado": "gzip" if USAR_GZIP else "texto puro",
            "raw_bytes_arquivos": raw_arq,
            "raw_bytes_texto": raw_txt,
            "raw_bytes_se_gzip": raw_gzm,
            "trusted_bytes_arquivos": tr_arq,
            "trusted_bytes_texto": tr_txt,
            "trusted_bytes_se_gzip": tr_gzm,
            "linhas_trusted_total": sum(r["linhas_trusted"] for r in resultados),
        },
        "teto": {
            "intervalo_util_bytes": [piso, raw_arq],
            "sugestao_bytes": teto,
            "observacao": "medição local (tamanho dos arquivos = bytes que o Athena varre); confirmar com consultas/executar.sh",
        },
    }
    ARQ_PERFIL.parent.mkdir(parents=True, exist_ok=True)
    ARQ_PERFIL.write_text(json.dumps(perfil, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    mb = lambda b: f"{b/1_048_576:,.2f} MB"  # noqa: E731
    print("\n=== RESUMO ===")
    print(f"  gravado em: {perfil['lake']['formato_gravado']}")
    print(f"  raw     : {mb(raw_arq)} em disco | texto {mb(raw_txt)} | se fosse gzip {mb(raw_gzm)}")
    print(f"  trusted : {mb(tr_arq)} em disco | texto {mb(tr_txt)} | se fosse gzip {mb(tr_gzm)} | "
          f"{perfil['lake']['linhas_trusted_total']:,} linhas")
    if teto:
        print(f"  teto sugerido (DECISÃO de custo): {teto:,} bytes  "
              f"[intervalo útil {piso:,} .. {raw_arq:,}]")
    else:
        print("  [!] a raw é pequena demais para um teto que a separe da trusted; veja DECISOES.md")
    maior = max([*(AQUI / "raw").rglob("*.csv*"), *(AQUI / "trusted").rglob("*.tsv*")],
                key=lambda p: p.stat().st_size, default=None)
    if maior:
        print(f"  maior arquivo: {maior.name} ({mb(maior.stat().st_size)})"
              + ("  [!] acima de 90 MB: o GitHub recusa arquivos > 100 MB" if maior.stat().st_size > 90e6 else ""))
    print(f"  perfil completo: {ARQ_PERFIL.relative_to(RAIZ_REPO)}")
    if not all(r["reconciliacao_ok"] for r in resultados):
        print("\n[ATENÇÃO] reconciliação com o resultado oficial NÃO bateu. Investigue antes de subir.")
        sys.exit(2)


if __name__ == "__main__":
    main()
