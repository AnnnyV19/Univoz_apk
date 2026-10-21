#!/usr/bin/env python3
"""Mira que trae un link ANTES de bajarlo o procesarlo: duracion, capitulos,
subtitulos y resolucion.

Sirve para decidir como partir un video largo de diccionario (uno con muchas
senas seguidas) en una muestra por sena:

  - Si tiene CAPITULOS, ya esta: cada capitulo trae nombre y tiempos exactos.
  - Si tiene SUBTITULOS subidos por el autor (no los automaticos), tambien
    sirven -- traen texto y tiempos.
  - Si no tiene ninguno de los dos, el texto solo esta quemado en la imagen y
    hace falta OCR, que es bastante mas trabajo.

Uso:
    python tools/inspeccionar.py "https://..."

Con --json escribe todo el volcado de metadatos a un archivo, por si hace
falta mirar algo que este resumen no imprime.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from descargar import _cargar_yt_dlp  # noqa: E402


def hhmmss(segundos):
    if segundos is None:
        return "?"
    s = int(segundos)
    return f"{s // 3600:d}:{(s % 3600) // 60:02d}:{s % 60:02d}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("url")
    ap.add_argument("--json", help="guarda el volcado completo de metadatos en este archivo")
    args = ap.parse_args()

    try:
        YoutubeDL = _cargar_yt_dlp()
    except ValueError as e:
        sys.exit(str(e))

    opciones = {"quiet": True, "no_warnings": True, "noplaylist": True, "skip_download": True}
    try:
        with YoutubeDL(opciones) as ydl:
            info = ydl.extract_info(args.url, download=False)
    except Exception as e:
        sys.exit(f"no pude leer el link ({e})")

    print(f"Titulo:    {info.get('title')}")
    print(f"Canal:     {info.get('uploader') or info.get('channel')}")
    print(f"Duracion:  {hhmmss(info.get('duration'))}")
    print(f"Licencia:  {info.get('license') or '(no declarada)'}")

    # --- capitulos: la mejor fuente de cortes ---
    capitulos = info.get("chapters") or []
    print(f"\nCAPITULOS: {len(capitulos)}")
    if capitulos:
        for c in capitulos[:15]:
            print(f"  {hhmmss(c.get('start_time'))} - {hhmmss(c.get('end_time'))}  {c.get('title')}")
        if len(capitulos) > 15:
            print(f"  ... y {len(capitulos) - 15} mas")
        print("\n  -> Sirven para cortar una muestra por sena con tiempos exactos.")
    else:
        print("  (ninguno)")

    # --- subtitulos ---
    subs = info.get("subtitles") or {}
    auto = info.get("automatic_captions") or {}
    print(f"\nSUBTITULOS subidos por el autor: {', '.join(subs.keys()) if subs else '(ninguno)'}")
    print(f"Subtitulos automaticos: {len(auto)} idioma(s) (no sirven: transcriben audio, no senas)")
    if subs:
        print("  -> Se pueden usar como fuente de texto + tiempos si no hay capitulos.")

    # --- formatos de video, para saber si habra H.264 ---
    formatos = [f for f in (info.get("formats") or []) if f.get("vcodec") and f.get("vcodec") != "none"]
    con_avc = [f for f in formatos if str(f.get("vcodec", "")).startswith("avc1")]
    alturas = sorted({f.get("height") for f in con_avc if f.get("height")})
    print(f"\nFormatos con H.264 (los que OpenCV lee sin problema): {alturas if alturas else 'NINGUNO'}")
    if not con_avc:
        print("  OJO: sin H.264 el archivo puede bajar bien pero no dar frames legibles.")

    # --- descripcion: a veces la lista de senas esta ahi, con tiempos ---
    desc = (info.get("description") or "").strip()
    if desc:
        lineas = desc.splitlines()
        print(f"\nDESCRIPCION ({len(lineas)} lineas, primeras 20):")
        for linea in lineas[:20]:
            print(f"  {linea}")
        if len(lineas) > 20:
            print(f"  ... y {len(lineas) - 20} mas")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(info, f, ensure_ascii=False, indent=2, default=str)
        print(f"\nMetadatos completos en {args.json}")


if __name__ == "__main__":
    main()
