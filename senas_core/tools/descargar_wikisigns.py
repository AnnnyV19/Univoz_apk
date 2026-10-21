#!/usr/bin/env python3
"""Baja los videos de YouTube de la lista que armo tools/wikisigns_a_enlaces.py,
en la estructura que lee el importador:

    datasets_lsm/wikisigns_lsm/videos/<Palabra>/<id_de_youtube>.mp4

Despues:
    python tools/importar_dataset_lsm.py --dataset wikisigns --probar 6
    python tools/importar_dataset_lsm.py --dataset wikisigns

El importador (a diferencia de ingest_enlaces.py) RECORTA los cuadros quietos
del inicio y el final de cada video, que es lo que hace que la sena quede bien
comparada; ingest_enlaces.py guarda el video completo.

Hace falta yt-dlp (pip install yt-dlp; ya esta en tools/requirements.txt).

Muchos videos de Wikisigns ya no existen o se volvieron privados (en una prueba
de 7, 3 eran privados). Eso se anota en datasets_lsm/wikisigns_lsm/descargas.csv
y no se reintenta (--reintentar para volver a probarlos). Si YouTube empieza a
pedir "confirmar que no eres un robot" o responde 429, el script se detiene
solo y se puede volver a correr mas tarde: sigue donde se quedo.

DERECHOS: son videos de sus autores en YouTube. Bajarlos puede ir contra los
terminos de YouTube; Wikisigns declara CC BY-SA 4.0 en sus paginas (exige dar
credito y compartir igual lo derivado). Usalo para estudio y pruebas y consulta
con Wikisigns antes de distribuir algo derivado. Ver tools/descargar.py.

USO (desde senas_core):
    python tools/descargar_wikisigns.py --seco         # cuenta, no baja nada
    python tools/descargar_wikisigns.py --probar 8     # 8 videos
    python tools/descargar_wikisigns.py                # todos (reanuda)
"""

import argparse
import csv
import datetime
import os
import random
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.abspath(os.path.join(HERE, ".."))
DATOS = os.path.join(RAIZ, "datasets_lsm", "wikisigns_lsm")


def log(*a):
    print(*a, flush=True)


def carpeta_segura(palabra, maximo=80):
    """Nombre de carpeta valido en Windows, conservando acentos y espacios."""
    limpio = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "", palabra).strip().rstrip(". ")
    limpio = re.sub(r"\s+", " ", limpio)
    return limpio[:maximo] or "sin_nombre"


def id_de_url(url):
    m = re.search(r"[?&]v=([A-Za-z0-9_-]{11})", url)
    return m.group(1) if m else None


def clasificar_error(msg):
    m = msg.lower()
    if "private video" in m:
        return "privado"
    if any(k in m for k in ("video unavailable", "has been removed", "no longer available",
                            "account associated", "terminated", "this video is not available",
                            "does not exist", "copyright")):
        return "no_disponible"
    if any(k in m for k in ("sign in to confirm", "not a bot", "429", "too many requests")):
        return "bloqueo"
    return "error"


def formato(altura):
    return (f"bv*[vcodec^=avc1][height<={altura}]/bv*[ext=mp4][height<={altura}]"
            f"/bv*[height<={altura}]/bv*/b")


def leer_estado(ruta):
    est = {}
    if os.path.exists(ruta):
        with open(ruta, encoding="utf-8", newline="") as f:
            for r in csv.DictReader(f):
                est[r["youtube_id"]] = r
    return est


def guardar_estado(ruta, est):
    os.makedirs(os.path.dirname(ruta), exist_ok=True)
    tmp = ruta + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["youtube_id", "palabra", "estado", "detalle", "fecha"])
        for r in est.values():
            w.writerow([r["youtube_id"], r["palabra"], r["estado"], r["detalle"], r["fecha"]])
    os.replace(tmp, ruta)


def ya_bajado(carpeta, vid):
    if not os.path.isdir(carpeta):
        return None
    for n in os.listdir(carpeta):
        if n.startswith(vid + ".") and not n.endswith((".part", ".ytdl", ".temp")):
            return os.path.join(carpeta, n)
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--datos", default=DATOS)
    ap.add_argument("--csv", help="registro de entradas (por defecto <datos>/entradas.csv)")
    ap.add_argument("--prueba", action="store_true", help="usa entradas.prueba.csv (la de --probar)")
    ap.add_argument("--destino", help="carpeta de videos (por defecto <datos>/videos)")
    ap.add_argument("--seco", action="store_true", help="cuenta y estima; no baja nada")
    ap.add_argument("--probar", type=int, metavar="N", help="solo N videos repartidos")
    ap.add_argument("--altura", type=int, default=720, help="alto maximo del video (720)")
    ap.add_argument("--pausa", type=float, default=2.0, help="segundos entre descargas (2, mas un poco al azar)")
    ap.add_argument("--reintentar", action="store_true", help="vuelve a probar los privados / no disponibles")
    args = ap.parse_args()

    ruta_csv = args.csv or os.path.join(args.datos, "entradas.prueba.csv" if args.prueba else "entradas.csv")
    if not os.path.exists(ruta_csv):
        raise SystemExit(f"no existe {ruta_csv}\nprimero:  python tools/wikisigns_a_enlaces.py")
    destino = args.destino or os.path.join(args.datos, "videos")
    ruta_estado = os.path.join(args.datos, "descargas.csv")

    filas = []
    with open(ruta_csv, encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            vid = id_de_url(r.get("youtube", ""))
            if vid and r.get("palabra"):
                filas.append((r["palabra"].strip(), vid))
    if not filas:
        raise SystemExit(f"{ruta_csv} no trae entradas con video")

    estado = leer_estado(ruta_estado)
    hechos = pendientes = muertos = 0
    por_bajar = []
    for palabra, vid in filas:
        carpeta = os.path.join(destino, carpeta_segura(palabra))
        if ya_bajado(carpeta, vid):
            hechos += 1
        elif vid in estado and estado[vid]["estado"] in ("privado", "no_disponible") and not args.reintentar:
            muertos += 1
        else:
            pendientes += 1
            por_bajar.append((palabra, vid, carpeta))
    log(f"{len(filas)} videos en la lista: {hechos} ya bajados, {muertos} marcados privados/no disponibles "
        f"(no se reintentan), {pendientes} por bajar")
    horas = pendientes * (args.pausa + 3) / 3600
    log(f"  destino: {destino}\n  estimado: ~{horas:.1f} h (≈{args.pausa + 3:.0f} s por video)")

    if args.seco:
        log("\n(--seco: no se bajo nada)")
        return 0

    if args.probar:
        n = max(1, min(args.probar, len(por_bajar)))
        por_bajar = [por_bajar[int(i * len(por_bajar) / n)] for i in range(n)]
        log(f"modo prueba: {len(por_bajar)} videos")
    if not por_bajar:
        log("\nNada por bajar. Siguiente paso:\n    python tools/importar_dataset_lsm.py --dataset wikisigns --probar 6")
        return 0

    try:
        from yt_dlp import YoutubeDL
    except ImportError:
        raise SystemExit("hace falta yt-dlp:   pip install yt-dlp")

    cuenta = {"ok": 0, "privado": 0, "no_disponible": 0, "error": 0}
    seguidos_malos = 0
    ahora = lambda: datetime.datetime.now().isoformat(timespec="seconds")
    try:
        for i, (palabra, vid, carpeta) in enumerate(por_bajar, 1):
            os.makedirs(carpeta, exist_ok=True)
            opciones = {
                "format": formato(args.altura),
                "outtmpl": os.path.join(carpeta, vid + ".%(ext)s"),
                "noplaylist": True, "overwrites": False, "quiet": True, "no_warnings": True,
            }
            try:
                with YoutubeDL(opciones) as ydl:
                    ydl.extract_info(f"https://www.youtube.com/watch?v={vid}", download=True)
                if not ya_bajado(carpeta, vid):
                    raise RuntimeError("se bajo pero no encuentro el archivo")
                est, detalle = "ok", ""
                seguidos_malos = 0
            except Exception as e:  # noqa: BLE001
                detalle = re.sub(r"\s+", " ", str(e))[:160]
                est = clasificar_error(detalle)
                if est in ("privado", "no_disponible"):
                    seguidos_malos = 0
                else:
                    seguidos_malos += 1
                try:
                    if not os.listdir(carpeta):
                        os.rmdir(carpeta)
                except OSError:
                    pass
            estado[vid] = {"youtube_id": vid, "palabra": palabra, "estado": est if est != "bloqueo" else "error",
                           "detalle": detalle, "fecha": ahora()}
            cuenta[est if est in cuenta else "error"] += 1
            log(f"  [{i:4d}/{len(por_bajar)}] {palabra[:34]:34s} {vid}  {est}"
                + (f"  ({detalle[:60]})" if est not in ("ok", "privado", "no_disponible") else ""))
            if i % 20 == 0:
                guardar_estado(ruta_estado, estado)
            if est == "bloqueo" or seguidos_malos >= 8:
                log("\nYouTube esta limitando las descargas (o hay un error repetido). Me detengo para no "
                    "empeorarlo; vuelve a correr mas tarde y sigue donde se quedo.")
                break
            time.sleep(args.pausa + random.uniform(0, 1.5))
    finally:
        guardar_estado(ruta_estado, estado)

    log(f"\nListo: {cuenta['ok']} bajados, {cuenta['privado']} privados, {cuenta['no_disponible']} no "
        f"disponibles, {cuenta['error']} con error (se reintentan al volver a correr).")
    log(f"  registro: {ruta_estado}")
    log("Siguiente paso:\n    python tools/importar_dataset_lsm.py --dataset wikisigns --probar 6")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("\ninterrumpido: lo bajado queda guardado; vuelve a correr para seguir")
        sys.exit(130)
