#!/usr/bin/env python3
"""Sube varias senas a partir de una LISTA DE LINKS, en vez de archivos que
ya tengas en el disco. Baja cada video con yt-dlp (tools/descargar.py) y
despues hace exactamente lo mismo que ingest_video.py / ingest_carpeta.py:
extrae landmarks, normaliza y guarda la muestra. Comparte ingest_un_video()
con los otros dos, asi que un cambio en como se sube un video aplica a los
tres por igual.

DERECHOS: bajar videos de terceros puede ir contra los terminos de servicio
del sitio y contra la licencia del video. Lo seguro son videos propios, o de
terceros con permiso o con licencia abierta. Ver tools/descargar.py.

FORMATO DE LA LISTA (un archivo de texto, .txt o .csv):

    # las lineas que empiezan con # se ignoran
    https://ejemplo.com/hola.mp4, hola, saludos
    https://ejemplo.com/gracias.mp4, gracias
    https://ejemplo.com/otro.mp4

Cada linea es: URL, palabra en espanol (opcional), categoria (opcional).
Si no pones la palabra, se usa el titulo del video para armar la glosa -- lo
que suele salir mal con titulos largos, asi que conviene escribirla.

La glosa se arma con la misma conversion que usa la app (a_glosa): "cómo
estás" -> COMO_ESTAS.

Antes de bajar nada, revisa el plan con --seco (no baja, no toca la base):
    python tools/ingest_enlaces.py --lista enlaces.txt --seco

Subir de verdad:
    python tools/ingest_enlaces.py --lista enlaces.txt --signer maria --mano derecha

Un link que falla no aborta el resto: queda anotado en el resumen final.
"""

import argparse
import csv
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import db  # noqa: E402
from descargar import DESCARGAS, descargar, es_url, titulo  # noqa: E402
from dotenv import load_dotenv  # noqa: E402
from extraer_landmarks import ExtractorLandmarks  # noqa: E402
from glosa import a_glosa  # noqa: E402
from ingest_video import ingest_un_video  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "android", "app", "src", "main", "assets")


def humanizar(gloss):
    return gloss.lower().replace("_", " ")


def leer_lista(ruta):
    """Devuelve [(url, palabra|None, categoria|None)] a partir del archivo.

    Acepta separadores coma o tabulador, con o sin espacios alrededor, y
    salta lineas vacias y comentarios (#).
    """
    entradas = []
    with open(ruta, encoding="utf-8-sig") as f:
        for n, linea in enumerate(f, start=1):
            linea = linea.strip()
            if not linea or linea.startswith("#"):
                continue
            partes = next(csv.reader([linea], skipinitialspace=True))
            partes = [p.strip() for p in partes]
            if len(partes) == 1 and "\t" in partes[0]:
                partes = [p.strip() for p in partes[0].split("\t")]
            url = partes[0]
            if not es_url(url):
                print(f"  linea {n}: no parece un link, la salteo -> {url}")
                continue
            palabra = partes[1] if len(partes) > 1 and partes[1] else None
            categoria = partes[2] if len(partes) > 2 and partes[2] else None
            entradas.append((url, palabra, categoria))
    return entradas


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lista", required=True, help="archivo de texto con un link por linea (ver formato arriba)")
    ap.add_argument("--categoria", help="categoria por defecto para los links que no traen una")
    ap.add_argument("--manos", type=int, choices=[1, 2], default=1)
    ap.add_argument("--es-estatica", action="store_true")
    ap.add_argument("--usa-no-manuales", action="store_true")
    ap.add_argument("--signer", help="nombre de quien aparece en los videos, para no mezclar train/test")
    ap.add_argument("--mano", choices=["izquierda", "derecha"], dest="mano_dominante")
    ap.add_argument("--espejo", action="store_true", help="si TODOS los videos de la lista quedaron espejeados")
    ap.add_argument("--aprobar", action="store_true")
    ap.add_argument("--generar-espejo", action="store_true", dest="generar_espejo")
    ap.add_argument("--carpeta-descargas", default=DESCARGAS, help=f"donde dejar los videos bajados (default: {DESCARGAS})")
    ap.add_argument("--seco", action="store_true", help="muestra el plan sin bajar nada ni tocar la base")
    ap.add_argument("--csv-resumen", help="ademas de imprimirlo, escribe el resumen en este CSV")
    ap.add_argument("--pose-model", default=os.path.join(ASSETS, "pose_landmarker_lite.task"))
    ap.add_argument("--hand-model", default=os.path.join(ASSETS, "hand_landmarker.task"))
    args = ap.parse_args()

    if not os.path.exists(args.lista):
        sys.exit(f"no existe la lista: {args.lista}")

    entradas = leer_lista(args.lista)
    if not entradas:
        sys.exit(f"no encontre links en {args.lista}")

    print(f"{len(entradas)} link(s) en {args.lista}:")
    planeados = []
    for url, palabra, categoria in entradas:
        gloss = a_glosa(palabra) if palabra else None
        espanol = palabra
        planeados.append((url, gloss, espanol, categoria or args.categoria))
        etiqueta = f"{gloss} ({espanol})" if gloss else "** glosa del titulo del video **"
        cat_txt = f"  ·  {categoria or args.categoria}" if (categoria or args.categoria) else ""
        print(f"  {url[:60]:<62} -> {etiqueta}{cat_txt}")

    if args.seco:
        print("\n(--seco: no se bajo ni se subio nada)")
        return

    if not os.path.exists(args.pose_model):
        sys.exit(f"no encuentro el modelo de pose en {args.pose_model} (ver CORRER.md)")
    if not os.path.exists(args.hand_model):
        sys.exit(f"no encuentro el modelo de manos en {args.hand_model} (ver CORRER.md)")

    load_dotenv()
    print("\nConectando a la base y cargando MediaPipe (una sola vez para toda la lista)...")
    conn = db.conectar()
    extractor = ExtractorLandmarks(args.pose_model, args.hand_model)
    resultados = []
    try:
        for i, (url, gloss, espanol, categoria) in enumerate(planeados, start=1):
            print(f"\n[{i}/{len(planeados)}] {url}")

            # Sin palabra escrita a mano, la glosa sale del titulo del video.
            if not gloss:
                try:
                    t = titulo(url)
                except ValueError as e:
                    print(f"  FALLO: {e}")
                    resultados.append({"url": url, "ok": False, "error": str(e)})
                    continue
                gloss = a_glosa(t)
                espanol = t.strip() if t else None
                if not gloss:
                    print("  SALTEADO: no se pudo armar una glosa del titulo del video")
                    resultados.append({"url": url, "ok": False, "error": "sin glosa"})
                    continue
                print(f"  titulo -> glosa: {gloss}")

            espanol = espanol or humanizar(gloss)

            try:
                video = descargar(url, carpeta=args.carpeta_descargas, nombre=gloss)
                print(f"  bajado: {os.path.basename(video)}")
                r = ingest_un_video(
                    conn, extractor,
                    video_path=video, gloss=gloss, espanol=espanol,
                    categoria=categoria, manos=args.manos,
                    es_estatica=args.es_estatica, usa_no_manuales=args.usa_no_manuales,
                    signer=args.signer, mano_dominante=args.mano_dominante,
                    espejo=args.espejo, generar_espejo=args.generar_espejo,
                    aprobar=args.aprobar,
                )
                conn.commit()
                print(f"  ok - {r['n_frames']} frames, calidad {r['quality_score']:.0%}, {r['estado']}")
                resultados.append({
                    "url": url, "gloss": gloss, "espanol": espanol, "ok": True,
                    "sample_id": r["sample_id"], "calidad": round(r["quality_score"], 3),
                    "estado": r["estado"],
                })
            except Exception as e:
                conn.rollback()
                print(f"  FALLO: {e}")
                resultados.append({"url": url, "gloss": gloss, "ok": False, "error": str(e)})
    finally:
        extractor.cerrar()
        conn.close()

    ok = [r for r in resultados if r["ok"]]
    fallidos = [r for r in resultados if not r["ok"]]
    print(f"\nListo: {len(ok)}/{len(resultados)} subidos.")
    if fallidos:
        print(f"{len(fallidos)} no se subieron:")
        for r in fallidos:
            print(f"  {r['url'][:60]}: {r['error']}")
    print(
        "\nQuedaron 'pendiente' (salvo que hayas usado --aprobar). Revisalas y "
        "aprobalas (INGESTA.md paso 7) y despues corre "
        "'python tools/exportar_paquete.py' para que entren al paquete de la app."
    )

    if args.csv_resumen:
        campos = ["url", "gloss", "espanol", "ok", "sample_id", "calidad", "estado", "error"]
        with open(args.csv_resumen, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=campos, extrasaction="ignore")
            w.writeheader()
            w.writerows(resultados)
        print(f"Resumen escrito en {args.csv_resumen}")


if __name__ == "__main__":
    main()
