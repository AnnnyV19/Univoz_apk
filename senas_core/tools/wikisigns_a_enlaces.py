#!/usr/bin/env python3
"""Arma una LISTA DE ENLACES con las senas de LSM de Wikisigns, lista para
tools/ingest_enlaces.py.

Wikisigns (https://www.wikisigns.org/list/es/lsm) es un diccionario colaborativo
con ~2,500 entradas de LSM. Cada entrada es una palabra en espanol y UN video de
YouTube (una persona de frente) -- no hay boton de descarga, asi que este script
solo recorre las paginas, saca el id del video de cada una y escribe:

    videos/enlaces_wikisigns.txt      <- lista (URL, palabra, categoria); sirve para ingest_enlaces.py
    datasets_lsm/wikisigns_lsm/entradas.csv   <- registro: palabra, pagina, video, licencia
    datasets_lsm/wikisigns_lsm/entradas.json  <- avance (permite reanudar)

Usa SOLO la biblioteca estandar. NO baja ningun video: eso lo hace despues
ingest_enlaces.py (con yt-dlp, como siempre).

RITMO: robots.txt de Wikisigns pide Crawl-delay: 10, asi que se espera 10 s entre
paginas (nunca menos). Son ~2,500 paginas: unas 7 horas. Se puede cortar con
Ctrl+C y reanuda donde se quedo. Dejalo corriendo de noche.

QUE SE SALTA (por defecto):
  - entradas sin video;
  - "(variedad distinta de ASL/DGS/...)": son senas de otras lenguas;
  - entradas sin letras ("@") o de una sola letra ("a"): ya estan en el alfabeto (--incluir-letras);
  - "(Senas Internacional)": nombres de paises en senas internacionales (--incluir-internacionales);
  - "(variedad distinta de LSM utilizado en ...)": variantes regionales (--incluir-regionales).
Las variantes "(A)", "(B)", "(LSM)", etc. SI entran, con la palabra sin el parentesis.

DERECHOS: la pagina de cada entrada dice "Creative Commons Attribution-ShareAlike
4.0" (CC BY-SA 4.0). Eso exige dar credito y compartir igual lo derivado. Los videos
son de YouTube y de sus autores: bajarlos puede ir contra los terminos de YouTube
(ver tools/descargar.py). Usalo para estudio/pruebas y consulta con Wikisigns antes
de distribuir algo derivado.

USO (desde senas_core):
    python tools/wikisigns_a_enlaces.py --seco          # cuenta (3 paginas, ~30 s)
    python tools/wikisigns_a_enlaces.py --probar 8      # 8 entradas repartidas (~80 s); deja videos/enlaces_wikisigns.txt.prueba.txt
    python tools/wikisigns_a_enlaces.py                 # todo (~7 h, reanuda)
    python tools/descargar_wikisigns.py                 # baja los videos (privados se anotan y se saltan)
    python tools/importar_dataset_lsm.py --dataset wikisigns --probar 6
    python tools/importar_dataset_lsm.py --dataset wikisigns
"""

import argparse
import csv
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.abspath(os.path.join(HERE, ".."))

BASE_DEFECTO = "https://www.wikisigns.org"
LISTA = "/list/es/lsm"
ESPERA_MIN = 10.0            # Crawl-delay de su robots.txt
UA = "UNIVOZ-lsm-lexicon/1.0 (proyecto academico de reconocimiento de LSM; lectura de paginas publicas)"

RX_ENLACE = re.compile(r'<a href="(/es/lsm/[^"#?]+)"[^>]*>([^<]+)</a>')
RX_PAGER = re.compile(r'href="[^"]*[?&]page=(\d+)"')
RX_YT = re.compile(r'youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{11})')
RX_PAREN_FINAL = re.compile(r'\s*\(([^()]*)\)\s*$')


def log(*a):
    print(*a, flush=True)


# ---------------------------------------------------------------------------
# red
# ---------------------------------------------------------------------------
class Cliente:
    def __init__(self, base, espera):
        self.base = base.rstrip("/")
        host = urllib.parse.urlparse(self.base).hostname or ""
        self.espera = max(espera, ESPERA_MIN) if host.endswith("wikisigns.org") else espera
        self._ultimo = 0.0

    def get(self, ruta, reintentos=3):
        url = self.base + urllib.parse.quote(ruta, safe="/%?=&:")
        for intento in range(1, reintentos + 1):
            falta = self.espera - (time.time() - self._ultimo)
            if falta > 0:
                time.sleep(falta)
            self._ultimo = time.time()
            try:
                req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "es"})
                with urllib.request.urlopen(req, timeout=40) as r:
                    return r.read().decode("utf-8", "replace")
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    return None
                if e.code in (429, 500, 502, 503, 504) and intento < reintentos:
                    espera = 60 * intento
                    log(f"    HTTP {e.code} en {ruta}; espero {espera} s y reintento")
                    time.sleep(espera)
                    continue
                raise
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                if intento < reintentos:
                    log(f"    sin respuesta ({e}); reintento en 30 s")
                    time.sleep(30)
                    continue
                raise
        return None


# ---------------------------------------------------------------------------
# analisis de paginas
# ---------------------------------------------------------------------------
def entradas_de_lista(texto):
    out = []
    for href, nombre in RX_ENLACE.findall(texto):
        nombre = html.unescape(nombre).strip()
        if nombre:
            out.append((href, nombre))
    return out


def ultima_pagina(texto):
    pags = [int(x) for x in RX_PAGER.findall(texto)]
    return max(pags) if pags else 0


def ids_de_video(texto):
    vistos, ids = set(), []
    for v in RX_YT.findall(texto):
        if v not in vistos:
            vistos.add(v)
            ids.append(v)
    return ids


def clasificar(nombre):
    """-> (palabra, motivo_de_salto|None, etiqueta). `palabra` es el nombre sin los
    parentesis finales; `etiqueta` el texto de esos parentesis (variante)."""
    palabra, etiquetas = nombre, []
    while True:
        m = RX_PAREN_FINAL.search(palabra)
        if not m:
            break
        etiquetas.insert(0, m.group(1).strip())
        palabra = palabra[:m.start()].rstrip()
    et = " | ".join(etiquetas)
    bajo = et.lower()
    if re.search(r"variedad distinta de (?!lsm)", bajo):
        return palabra, "otra lengua", et
    if "variedad distinta de lsm" in bajo:
        return palabra, "regional", et
    if re.search(r"se[ñn]as internacional", bajo):
        return palabra, "internacional", et
    if not re.search(r"[A-Za-z0-9ÁÉÍÓÚÜÑáéíóúüñ]", palabra):
        return palabra, "sin letras", et          # p. ej. "@": la glosa saldria vacia
    if len(palabra) == 1 and palabra.isalpha():
        return palabra, "letra suelta", et        # ya estan en el alfabeto de la app
    return palabra, None, et


# ---------------------------------------------------------------------------
# avance
# ---------------------------------------------------------------------------
def cargar(ruta):
    if os.path.exists(ruta):
        with open(ruta, encoding="utf-8") as f:
            return json.load(f)
    return {}


def guardar(ruta, datos):
    os.makedirs(os.path.dirname(ruta), exist_ok=True)
    tmp = ruta + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(datos, f, ensure_ascii=False, indent=0)
    os.replace(tmp, ruta)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--base", default=BASE_DEFECTO, help=argparse.SUPPRESS)
    ap.add_argument("--salida", default=os.path.join(RAIZ, "videos", "enlaces_wikisigns.txt"))
    ap.add_argument("--datos", default=os.path.join(RAIZ, "datasets_lsm", "wikisigns_lsm"))
    ap.add_argument("--espera", type=float, default=ESPERA_MIN,
                    help="segundos entre paginas (minimo 10, el Crawl-delay de Wikisigns)")
    ap.add_argument("--seco", action="store_true", help="solo cuenta (lee las 3 paginas de la lista)")
    ap.add_argument("--probar", type=int, metavar="N", help="solo N entradas repartidas")
    ap.add_argument("--incluir-internacionales", action="store_true")
    ap.add_argument("--incluir-regionales", action="store_true")
    ap.add_argument("--incluir-letras", action="store_true", help="tambien las entradas de una sola letra")
    ap.add_argument("--desde-cero", action="store_true", help="ignora el avance guardado")
    args = ap.parse_args()

    cli = Cliente(args.base, args.espera)
    ruta_json = os.path.join(args.datos, "entradas.json")
    ruta_csv = os.path.join(args.datos, "entradas.csv")
    estado = {} if args.desde_cero else cargar(ruta_json)

    # --- 1. la lista -------------------------------------------------------
    log(f"Leyendo la lista de {cli.base}{LISTA} (espera {cli.espera:.0f} s entre paginas)")
    entradas = {}
    primera = cli.get(LISTA)
    if primera is None:
        raise SystemExit("no pude leer la lista de Wikisigns")
    ultima = ultima_pagina(primera)
    paginas = [primera] + [cli.get(f"{LISTA}?page={p}") or "" for p in range(1, ultima + 1)]
    for txt in paginas:
        for href, nombre in entradas_de_lista(txt):
            entradas.setdefault(href, nombre)
    log(f"  {len(entradas)} entradas en {len(paginas)} paginas de lista")

    plan, saltos = [], {}
    for href, nombre in entradas.items():
        palabra, motivo, et = clasificar(nombre)
        if motivo == "internacional" and args.incluir_internacionales:
            motivo = None
        if motivo == "regional" and args.incluir_regionales:
            motivo = None
        if motivo == "letra suelta" and args.incluir_letras:
            motivo = None
        if motivo:
            saltos[motivo] = saltos.get(motivo, 0) + 1
            continue
        plan.append((href, nombre, palabra, et))
    plan.sort(key=lambda x: x[1].lower())
    resumen = ", ".join(f"{n} {k}" for k, n in sorted(saltos.items())) or "ninguna"
    log(f"  se salta: {resumen}.  Quedan {len(plan)} entradas por revisar")
    pendientes = [p for p in plan if p[0] not in estado or estado[p[0]].get("error")]
    horas = len(pendientes) * cli.espera / 3600
    log(f"  ya revisadas antes: {len(plan) - len(pendientes)};  faltan {len(pendientes)}"
        f"  (~{horas:.1f} h a {cli.espera:.0f} s por pagina)")

    if args.seco:
        log("\n(--seco: no se leyo ninguna entrada ni se escribio nada)")
        return 0

    if args.probar:
        fuente = plan                      # la prueba no depende del avance real
        n = max(1, min(args.probar, len(fuente)))
        pendientes = [fuente[int(i * len(fuente) / n)] for i in range(n)]
        log(f"modo prueba: {len(pendientes)} entradas repartidas")
        estado = {}                       # la prueba no mezcla ni pisa el avance real
        ruta_json += ".prueba"
        args.salida += ".prueba.txt"
        ruta_csv = os.path.join(args.datos, "entradas.prueba.csv")
        plan = pendientes

    # --- 2. cada entrada -> id del video -----------------------------------
    try:
        for i, (href, nombre, palabra, et) in enumerate(pendientes, 1):
            try:
                txt = cli.get(href)
            except Exception as e:  # una pagina rota no tira todo
                log(f"  [{i}/{len(pendientes)}] {nombre}: ERROR {e}")
                estado[href] = {"nombre": nombre, "palabra": palabra, "etiqueta": et, "error": str(e)[:120]}
                continue
            ids = ids_de_video(txt or "")
            estado[href] = {"nombre": nombre, "palabra": palabra, "etiqueta": et, "yt": ids}
            log(f"  [{i:4d}/{len(pendientes)}] {nombre[:40]:40s} {'video ' + ids[0] if ids else 'SIN VIDEO'}")
            if i % 25 == 0:
                guardar(ruta_json, estado)
    finally:
        guardar(ruta_json, estado)

    # --- 3. salidas --------------------------------------------------------
    filas = []
    for href, nombre, palabra, et in plan:
        e = estado.get(href)
        if not e or not e.get("yt"):
            continue
        for vid in e["yt"][:1]:
            filas.append((palabra, nombre, base_url(cli.base, href), vid))
    os.makedirs(os.path.dirname(args.salida), exist_ok=True)
    os.makedirs(args.datos, exist_ok=True)
    with open(args.salida, "w", encoding="utf-8", newline="") as f:
        f.write("# Wikisigns LSM (CC BY-SA 4.0), https://www.wikisigns.org/list/es/lsm\n")
        f.write("# URL, palabra, categoria   (generado por tools/wikisigns_a_enlaces.py)\n")
        for palabra, _nombre, _pag, vid in filas:
            palabra_limpia = re.sub(r"\s+", " ", palabra.replace(",", " ")).strip()
            f.write(f"https://www.youtube.com/watch?v={vid}, {palabra_limpia}, general\n")
    with open(ruta_csv, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["palabra", "entrada_wikisigns", "pagina", "youtube", "licencia"])
        for palabra, nombre, pag, vid in filas:
            w.writerow([palabra, nombre, pag, f"https://www.youtube.com/watch?v={vid}", "CC BY-SA 4.0"])

    sin_video = sum(1 for h, *_ in plan if h in estado and not estado[h].get("yt"))
    errores = sum(1 for h, *_ in plan if h in estado and estado[h].get("error"))
    log(f"\nListo: {len(filas)} enlaces con video en {args.salida}")
    log(f"  entradas sin video: {sin_video};  con error (se reintentan al volver a correr): {errores}")
    log(f"  registro con licencia y pagina de cada una: {ruta_csv}")
    log("Siguiente paso (baja los videos y los importa recortando los cuadros quietos):")
    log("    python tools/descargar_wikisigns.py" + (" --prueba" if args.probar else ""))
    log("    python tools/importar_dataset_lsm.py --dataset wikisigns --probar 6")
    if args.probar:
        log("  (esto fue una PRUEBA; la lista completa se arma corriendo este script sin --probar)")
    return 0


def base_url(base, href):
    return base.rstrip("/") + href


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("\ninterrumpido: lo avanzado queda guardado; vuelve a correr para seguir")
        sys.exit(130)
