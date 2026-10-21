#!/usr/bin/env python3
"""Baja los videos del dataset ITESO-MX-100 (Mendeley Data) a tu disco.

  ITESO-MX-100, Victor Hugo Martinez Sanchez (ITESO), Mendeley Data V1, 2026
  DOI 10.17632/g45jkzys4f.1   licencia CC BY 4.0 (hay que dar el credito)

Lo que hay publicado (leido de la pagina el 2026-10-06; la descripcion habla de
100 senas y 5,000 videos, pero el registro trae menos):
  49 carpetas (una por sena, de 'Abrir' a 'Explicar'; 7 de ellas vacias),
  2,159 archivos (2,107 .mp4 y 52 .mov de iPhone en 'Cansado'), ~10.7 GB.

Cada video se guarda con el nombre  <Carpeta>__<archivo>  en UNA sola carpeta
(los archivos se llaman 1.mp4, 2.mp4... en todas las carpetas y se pisarian):
    Abrir__1.mp4, Abrir__2.mp4, Agua__1.mp4, ...

Como se usa:
    python tools/descargar_iteso.py --seco         # cuenta, pesa y revisa tu disco; no baja nada
    python tools/descargar_iteso.py --probar 6     # baja 6 videos de prueba
    python tools/descargar_iteso.py                # baja todo (reanuda si se corta)

Cada archivo se verifica contra el SHA-256 que publica Mendeley; si algo se
corta, vuelve a correr el mismo comando y sigue donde se quedo. Para meter los
landmarks a la base:
    python tools/importar_dataset_lsm.py --dataset iteso

Si Mendeley te rechaza (403) desde Python, baja el zip a mano desde la pagina
(boton "Download All") y usa:  python tools/descargar_iteso.py --zip RUTA.zip
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import time
import unicodedata
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests

HERE = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.dirname(HERE)

ID = "g45jkzys4f"
VERSION = 1
API = "https://data.mendeley.com/public-api/datasets/" + ID
DESTINO_DEFECTO = os.path.join(RAIZ, "datasets_lsm", "mendeley_" + ID, "videos")
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36",
      "Accept": "application/json, */*"}
EXT = (".mp4", ".mov", ".avi", ".mkv")


def mb(n):
    return n / 1e6


def nombre_plano(carpeta, archivo, usados):
    """'Abrir' + '10.mp4' -> 'Abrir__10.mp4'. Sin espacios al borde ni dentro del nombre."""
    carpeta = re.sub(r"\s+", " ", unicodedata.normalize("NFC", carpeta)).strip()
    stem, ext = os.path.splitext(unicodedata.normalize("NFC", archivo))
    stem = re.sub(r"\s+", "_", stem.strip())
    base = f"{carpeta}__{stem}"
    nombre, k = base + ext.lower(), 1
    while nombre.lower() in usados:       # ' 52.mp4' y '52.mp4' en la misma carpeta
        k += 1
        nombre = f"{base}_{k}{ext.lower()}"
    usados.add(nombre.lower())
    return nombre


# ---------------------------------------------------------------------------
# lista de archivos (API publica de Mendeley, sin cuenta)
# ---------------------------------------------------------------------------
def pedir(url, **kw):
    r = requests.get(url, headers=UA, timeout=60, **kw)
    if r.status_code == 403:
        raise SystemExit("Mendeley rechazo la peticion (403). Baja el zip a mano desde la pagina "
                         "(Download All) y corre:  python tools/descargar_iteso.py --zip RUTA.zip")
    r.raise_for_status()
    return r.json()


def lista_archivos():
    carpetas = pedir(f"{API}/folders/{VERSION}")
    usados_por_carpeta, out = {}, []
    for c in carpetas:
        usados = usados_por_carpeta.setdefault(c["name"], set())
        filas = pedir(f"{API}/files", params={"folder_id": c["id"], "version": VERSION,
                                              "$start": 0, "$limit": 1000})
        for f in sorted(filas, key=lambda x: x["filename"]):
            cd = f.get("content_details") or {}
            if not f["filename"].lower().endswith(EXT):
                continue
            url = cd.get("download_url") or (
                f"https://data.mendeley.com/public-files/datasets/{ID}/files/{f['id']}/file_downloaded")
            out.append({"carpeta": c["name"], "original": f["filename"],
                        "nombre": nombre_plano(c["name"], f["filename"], usados),
                        "tam": int(f.get("size") or cd.get("size") or 0),
                        "sha256": (cd.get("sha256_hash") or "").lower(), "url": url})
    return carpetas, out


# ---------------------------------------------------------------------------
# descarga de un archivo (reanuda, verifica)
# ---------------------------------------------------------------------------
def sha256_de(ruta):
    h = hashlib.sha256()
    with open(ruta, "rb") as f:
        for bloque in iter(lambda: f.read(1 << 20), b""):
            h.update(bloque)
    return h.hexdigest()


def bajar(a, destino):
    """Devuelve (nombre, estado, bytes_bajados). estado: ok | ya | error:<motivo>."""
    ruta = os.path.join(destino, a["nombre"])
    if os.path.exists(ruta) and a["tam"] and os.path.getsize(ruta) == a["tam"]:
        return a["nombre"], "ya", 0
    parcial = ruta + ".part"
    bajados = 0
    ultimo = ""
    for intento in range(4):
        try:
            tengo = os.path.getsize(parcial) if os.path.exists(parcial) else 0
            h = dict(UA)
            if tengo:
                h["Range"] = f"bytes={tengo}-"
            with requests.get(a["url"], headers=h, stream=True, timeout=(30, 120)) as r:
                if r.status_code == 416:                     # ya estaba completo
                    pass
                else:
                    if r.status_code == 403:
                        return a["nombre"], "error:403 (Mendeley rechazo la descarga)", bajados
                    r.raise_for_status()
                    if tengo and r.status_code != 206:       # el servidor ignoro Range: de cero
                        tengo = 0
                    with open(parcial, "ab" if tengo else "wb") as f:
                        for bloque in r.iter_content(1 << 20):
                            f.write(bloque)
                            bajados += len(bloque)
            if a["tam"] and os.path.getsize(parcial) != a["tam"]:
                ultimo = f"tamano {os.path.getsize(parcial)} en vez de {a['tam']}"
                if os.path.getsize(parcial) > a["tam"]:
                    os.remove(parcial)
                time.sleep(2 * (intento + 1))
                continue
            if a["sha256"] and sha256_de(parcial) != a["sha256"]:
                ultimo = "SHA-256 no coincide"
                os.remove(parcial)
                continue
            os.replace(parcial, ruta)
            return a["nombre"], "ok", bajados
        except (requests.RequestException, OSError) as e:
            ultimo = str(e)[:120]
            time.sleep(2 * (intento + 1))
    return a["nombre"], "error:" + ultimo, bajados


# ---------------------------------------------------------------------------
# alternativa: zip bajado a mano
# ---------------------------------------------------------------------------
def desde_zip(ruta_zip, destino):
    usados_por_carpeta, n, mal = {}, 0, 0
    with zipfile.ZipFile(ruta_zip) as z:
        for info in z.infolist():
            if info.is_dir() or not info.filename.lower().endswith(EXT):
                continue
            partes = [p for p in info.filename.replace("\\", "/").split("/") if p]
            if len(partes) < 2:
                mal += 1
                continue
            carpeta, archivo = partes[-2], partes[-1]
            usados = usados_por_carpeta.setdefault(carpeta, set())
            nombre = nombre_plano(carpeta, archivo, usados)
            ruta = os.path.join(destino, nombre)
            if os.path.exists(ruta) and os.path.getsize(ruta) == info.file_size:
                continue
            with z.open(info) as src, open(ruta + ".part", "wb") as dst:
                shutil.copyfileobj(src, dst)
            os.replace(ruta + ".part", ruta)
            n += 1
    print(f"Extraidos {n} videos a {destino}" + (f" ({mal} archivos sueltos ignorados)" if mal else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--destino", default=DESTINO_DEFECTO, help="carpeta donde quedan los videos")
    ap.add_argument("--seco", action="store_true", help="solo cuenta y revisa el disco")
    ap.add_argument("--probar", type=int, metavar="N", help="solo N videos, repartidos entre las carpetas")
    ap.add_argument("--carpetas", help="solo estas (separadas por coma): Abrir,Agua")
    ap.add_argument("--solo-mp4", action="store_true", help="omite los .mov de iPhone")
    ap.add_argument("--hilos", type=int, default=3, help="descargas en paralelo (3)")
    ap.add_argument("--verificar", action="store_true",
                    help="vuelve a comprobar el SHA-256 de lo que ya esta bajado")
    ap.add_argument("--zip", metavar="RUTA", help="en vez de bajar, extrae un ITESO-MX-100.zip que ya tengas")
    args = ap.parse_args()
    for flujo in (sys.stdout, sys.stderr):
        try:
            flujo.reconfigure(errors="replace")
        except Exception:
            pass

    os.makedirs(args.destino, exist_ok=True)
    if args.zip:
        desde_zip(args.zip, args.destino)
        return 0

    print("Leyendo la lista de archivos de Mendeley...")
    carpetas, archivos = lista_archivos()
    con_videos = {a["carpeta"] for a in archivos}
    if args.carpetas:
        quiero = {unicodedata.normalize("NFC", c.strip()).lower() for c in args.carpetas.split(",")}
        archivos = [a for a in archivos if unicodedata.normalize("NFC", a["carpeta"]).lower() in quiero]
    if args.solo_mp4:
        archivos = [a for a in archivos if a["nombre"].lower().endswith(".mp4")]
    if not archivos:
        print("No hay archivos que bajar con esos filtros.")
        return 1
    with open(os.path.join(os.path.dirname(args.destino), "manifiesto_iteso.json"), "w",
              encoding="utf-8") as f:
        json.dump(archivos, f, ensure_ascii=False, indent=1)

    if args.probar:
        por = {}
        for a in archivos:
            por.setdefault(a["carpeta"], []).append(a)
        nombres = sorted(por)
        cuantas = max(1, min(len(nombres), args.probar))
        elegidas = [nombres[int(i * len(nombres) / cuantas)] for i in range(cuantas)]
        archivos = [por[c][0] for c in elegidas][:args.probar]
        for c in elegidas:
            for a in por[c][1:]:
                if len(archivos) >= args.probar:
                    break
                if a not in archivos:
                    archivos.append(a)

    pendientes = []
    for a in archivos:
        ruta = os.path.join(args.destino, a["nombre"])
        if os.path.exists(ruta) and a["tam"] and os.path.getsize(ruta) == a["tam"]:
            if args.verificar and a["sha256"] and sha256_de(ruta) != a["sha256"]:
                print(f"  SHA-256 distinto, se vuelve a bajar: {a['nombre']}")
                os.remove(ruta)
            else:
                continue
        pendientes.append(a)

    total = sum(a["tam"] for a in archivos)
    falta = sum(a["tam"] for a in pendientes)
    vacias = sorted({c["name"] for c in carpetas} - con_videos)
    print(f"\nCarpetas con videos: {len({a['carpeta'] for a in archivos})} de {len(carpetas)}"
          + (f"  (vacias en Mendeley: {', '.join(vacias)})" if vacias and not args.carpetas else ""))
    print(f"Archivos: {len(archivos)}  ({mb(total) / 1000:.2f} GB)   por bajar: {len(pendientes)}  "
          f"({mb(falta) / 1000:.2f} GB)")
    libre = shutil.disk_usage(args.destino).free
    print(f"Espacio libre en el disco de destino: {libre / 1e9:.1f} GB")
    if falta * 1.02 > libre:
        print("NO HAY ESPACIO suficiente. Libera disco o usa --destino con otra unidad.")
        return 2
    if args.seco or not pendientes:
        print("\n[seco] no se bajo nada." if args.seco else "\nTodo estaba ya bajado.")
        return 0

    print(f"\nBajando a {args.destino}  ({args.hilos} en paralelo; se puede interrumpir y volver a correr)")
    t0, hecho, bytes_ok, errores = time.monotonic(), 0, 0, []
    with ThreadPoolExecutor(max_workers=max(1, args.hilos)) as ex:
        futuros = {ex.submit(bajar, a, args.destino): a for a in pendientes}
        for fut in as_completed(futuros):
            nombre, estado, n = fut.result()
            hecho += 1
            bytes_ok += n
            if estado.startswith("error"):
                errores.append((nombre, estado[6:]))
            if hecho % 25 == 0 or hecho == len(pendientes) or estado.startswith("error"):
                seg = time.monotonic() - t0
                eta = seg / hecho * (len(pendientes) - hecho)
                print(f"  {hecho}/{len(pendientes)}  {mb(bytes_ok) / 1000:.2f} GB  "
                      f"{mb(bytes_ok) / max(seg, 1):.1f} MB/s  faltan ~{int(eta // 60)} min"
                      + (f"   ERROR {nombre}: {estado[6:]}" if estado.startswith("error") else ""))
    print(f"\nListo: {hecho - len(errores)} videos bajados y verificados, {len(errores)} con problemas.")
    for nombre, motivo in errores[:15]:
        print(f"  {nombre}: {motivo}")
    if errores:
        print("Vuelve a correr el mismo comando: reintenta solo los que faltan.")
    else:
        print("Siguiente paso:  python tools/importar_dataset_lsm.py --dataset iteso --probar 6")
    return 1 if errores else 0


if __name__ == "__main__":
    sys.exit(main())
