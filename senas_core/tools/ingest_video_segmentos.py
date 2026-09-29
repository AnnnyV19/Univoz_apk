#!/usr/bin/env python3
"""Sube MUCHAS señas de una sola vez a partir de UN SOLO video donde
aparecen una despues de la otra -- por ejemplo, un video del abecedario
donde en cada tramo se ve una letra distinta. Recorta cada tramo segun los
tiempos que le indiques en un CSV, y sube cada tramo como una muestra
independiente -- comparte toda la logica de extraccion/normalizacion/
guardado con ingest_video.py (ingest_un_video), igual que hace
ingest_carpeta.py.

Por que hace falta esto y no alcanza con ingest_video.py: ese script sube
UN video = UNA seña. Este es para el caso de un video ya grabado (por
ejemplo bajado de un link) donde UN SOLO archivo tiene VARIAS señas
seguidas -- vos le decis en que tramo de tiempo esta cada una y este
script se encarga de recortar y subir cada una por separado, sin que
tengas que grabar de nuevo con el celular.

## 1. El archivo de tiempos (--segmentos)

Un CSV de texto plano con una fila por seña, columnas:

    inicio,fin,gloss,espanol,categoria

Por ejemplo (un abecedario -- ver tools/ejemplo_segmentos.csv):

    inicio,fin,gloss,espanol,categoria
    0:03,0:05,A,a,abecedario
    0:06,0:08,B,be,abecedario
    0:09,0:11,C,ce,abecedario

- inicio/fin: en segundos (3.5) o en minutos:segundos (0:03, 1:02:03).
- gloss: obligatoria.
- espanol: opcional -- si la dejas vacia, se usa el gloss en minuscula.
- categoria: opcional -- si la dejas vacia, se usa --categoria (o ninguna).

Los tiempos salen de mirar el video una vez y anotar donde arranca y
termina cada letra. Si la letra esta dibujada/incrustada en la imagen (no
es una pista de subtitulos real con sus propios tiempos), no hay forma de
sacar esto de forma automatica -- hay que anotarlo a mano una vez por
video, pero sigue siendo mucho menos trabajo que grabar cada letra vos
mismo.

## 2. El video (--video)

Puede ser un archivo local o un link (YouTube y varios sitios mas, via
yt-dlp) -- si es un link, se descarga primero a una carpeta temporal y se
borra sola al terminar. Para usar un link hace falta el paquete opcional
yt-dlp:
    pip install yt-dlp

## Uso basico

    python tools/ingest_video_segmentos.py \\
        --video https://www.youtube.com/watch?v=XXXXXXXX \\
        --segmentos abecedario_tiempos.csv \\
        --categoria abecedario \\
        --signer TuNombre

Antes de subir nada de verdad, revisa con --seco que los tiempos y las
glosas sean las que esperas -- no descarga, no recorta, no toca la base:

    python tools/ingest_video_segmentos.py --video abecedario.mp4 \\
        --segmentos abecedario_tiempos.csv --seco

Deja al menos medio segundo de margen entre el fin de una seña y el
inicio de la siguiente en el CSV: el recorte de cada tramo puede caer uno
o dos frames antes/despues del tiempo exacto que pusiste (ver
recortar_segmento), y ese margen evita que se mezclen dos señas vecinas.

Requiere lo mismo que ingest_video.py (ver ese archivo y CORRER.md) mas,
opcionalmente, yt-dlp si vas a usar un link en vez de un archivo local.
"""

import argparse
import csv
import os
import sys
import tempfile

import cv2

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import db  # noqa: E402
from dotenv import load_dotenv  # noqa: E402
from extraer_landmarks import ExtractorLandmarks  # noqa: E402
from ingest_video import ingest_un_video  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "android", "app", "src", "main", "assets")


def parsear_tiempo(texto):
    """Acepta segundos ("3.5") o "MM:SS" / "HH:MM:SS" ("1:02:03")."""
    texto = texto.strip()
    if ":" not in texto:
        return float(texto)
    partes = [float(p) for p in texto.split(":")]
    if len(partes) == 2:
        minutos, segundos = partes
        return minutos * 60 + segundos
    if len(partes) == 3:
        horas, minutos, segundos = partes
        return horas * 3600 + minutos * 60 + segundos
    raise ValueError(f"tiempo invalido: {texto!r} (usa segundos o MM:SS / HH:MM:SS)")


def leer_segmentos(ruta, categoria_default):
    """Lee el CSV de tiempos. Devuelve una lista de dicts con inicio, fin,
    gloss, espanol, categoria -- ya con los defaults aplicados."""
    segmentos = []
    with open(ruta, newline="", encoding="utf-8-sig") as f:
        lector = csv.DictReader(f)
        columnas = {c.strip().lower() for c in (lector.fieldnames or [])}
        faltantes = {"inicio", "fin", "gloss"} - columnas
        if faltantes:
            raise ValueError(
                f"al archivo de segmentos le faltan columnas: {', '.join(sorted(faltantes))} "
                f"(tiene: {', '.join(lector.fieldnames or [])})"
            )
        for i, fila_cruda in enumerate(lector, start=2):  # fila 1 es el encabezado
            fila = {k.strip().lower(): (v or "").strip() for k, v in fila_cruda.items()}
            if not fila.get("gloss"):
                continue  # fila vacia, la salteamos
            try:
                inicio = parsear_tiempo(fila["inicio"])
                fin = parsear_tiempo(fila["fin"])
            except ValueError as e:
                raise ValueError(f"fila {i} del CSV de segmentos: {e}") from e
            if fin <= inicio:
                raise ValueError(
                    f"fila {i} del CSV de segmentos: fin ({fila['fin']}) "
                    f"no es mayor que inicio ({fila['inicio']})"
                )
            gloss = fila["gloss"]
            espanol = fila.get("espanol") or gloss.lower()
            categoria = fila.get("categoria") or categoria_default
            segmentos.append({
                "inicio": inicio, "fin": fin, "gloss": gloss,
                "espanol": espanol, "categoria": categoria,
            })
    return segmentos


def descargar_si_es_link(video, carpeta_tmp):
    """Si `video` es un link (http/https), lo descarga a carpeta_tmp con
    yt-dlp y devuelve la ruta local. Si ya es un archivo local, lo
    devuelve tal cual."""
    if not video.startswith(("http://", "https://")):
        return video
    try:
        import yt_dlp
    except ImportError:
        sys.exit(
            "para usar un link de video hace falta el paquete opcional yt-dlp:\n"
            "  pip install yt-dlp"
        )
    destino = os.path.join(carpeta_tmp, "fuente.%(ext)s")
    print(f"Descargando {video} ...")
    opciones = {
        "outtmpl": destino,
        "format": "mp4/best",
        "quiet": True,
        "no_warnings": True,
    }
    with yt_dlp.YoutubeDL(opciones) as ydl:
        info = ydl.extract_info(video, download=True)
        ruta = ydl.prepare_filename(info)
    if not os.path.exists(ruta):
        sys.exit(f"la descarga parecio terminar pero no encuentro el archivo: {ruta}")
    print(f"  descargado: {os.path.basename(ruta)}")
    return ruta


def recortar_segmento(origen, destino, inicio_seg, fin_seg):
    """Escribe en `destino` el tramo [inicio_seg, fin_seg) de `origen`,
    usando solo OpenCV -- sin depender de tener el binario de ffmpeg
    instalado aparte, ya que opencv-python ya es una dependencia dura de
    este proyecto. El corte puede caer uno o dos frames antes/despues del
    tiempo pedido segun como este codificado el video (la busqueda por
    milisegundos de OpenCV no siempre es cuadro-exacta) -- por eso el
    modulo recomienda dejar medio segundo de margen entre señas en el CSV.

    Devuelve cuantos frames escribio (0 si el tramo quedo vacio, por
    ejemplo si el video es mas corto que inicio_seg)."""
    cap = cv2.VideoCapture(origen)
    if not cap.isOpened():
        raise RuntimeError(f"no se pudo abrir el video: {origen}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    ancho = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    alto = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap.set(cv2.CAP_PROP_POS_MSEC, inicio_seg * 1000)

    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    out = cv2.VideoWriter(destino, fourcc, fps, (ancho, alto))
    escritos = 0
    try:
        while True:
            t_actual = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000.0
            if t_actual >= fin_seg:
                break
            ok, frame = cap.read()
            if not ok:
                break
            out.write(frame)
            escritos += 1
    finally:
        cap.release()
        out.release()
    return escritos


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", required=True, help="archivo de video local, o un link (requiere yt-dlp)")
    ap.add_argument("--segmentos", required=True, help="CSV con columnas inicio,fin,gloss,espanol,categoria")
    ap.add_argument("--categoria", help="categoria por defecto para las filas que no traigan una")
    ap.add_argument("--manos", type=int, choices=[1, 2], default=1)
    ap.add_argument(
        "--es-estatica", action="store_true", dest="es_estatica",
        help=(
            "las señas de este video son una sola postura sin movimiento. "
            "Ojo si tu alfabeto tiene letras CON movimiento (como suele pasar "
            "con J o Z en varias lenguas de señas): no uses este flag para "
            "todo el video, corre esas letras aparte en otra pasada sin el."
        ),
    )
    ap.add_argument("--usa-no-manuales", action="store_true")
    ap.add_argument("--signer", help="tu nombre (o el de quien sena en el video), igual que en ingest_video.py")
    ap.add_argument("--mano", choices=["izquierda", "derecha"], dest="mano_dominante")
    ap.add_argument("--espejo", action="store_true", help="si el video quedo espejeado (modo selfie)")
    ap.add_argument("--aprobar", action="store_true")
    ap.add_argument("--generar-espejo", action="store_true", dest="generar_espejo")
    ap.add_argument(
        "--mascara",
        help=(
            "rectangulo a tapar antes de analizar, x0,y0,x1,y1 en fracciones "
            "del cuadro (ej. 0.66,0.06,1.00,0.90). Para los videos de "
            "diccionario que traen un recuadro chico con un segundo plano de "
            "la misma persona: sin taparlo, el detector encuentra tambien la "
            "mano de ese recuadro. tools/segmentar_video.py --solo-roi dibuja "
            "el rectangulo sobre un fotograma para verificarlo antes."
        ),
    )
    ap.add_argument("--seco", action="store_true", help="muestra el plan (tiempos y glosas) sin descargar, recortar ni tocar la base")
    ap.add_argument("--csv-resumen", help="ademas de imprimir el resumen, lo escribe en este CSV")
    ap.add_argument("--pose-model", default=os.path.join(ASSETS, "pose_landmarker_lite.task"))
    ap.add_argument("--hand-model", default=os.path.join(ASSETS, "hand_landmarker.task"))
    args = ap.parse_args()

    mascara = None
    if args.mascara:
        try:
            mascara = tuple(float(v) for v in args.mascara.split(","))
        except ValueError:
            sys.exit("--mascara tiene que ser 4 numeros separados por comas")
        if len(mascara) != 4 or not (0 <= mascara[0] < mascara[2] <= 1
                                     and 0 <= mascara[1] < mascara[3] <= 1):
            sys.exit("--mascara: 4 valores de 0 a 1, con x0<x1 y y0<y1")

    try:
        segmentos = leer_segmentos(args.segmentos, args.categoria)
    except (ValueError, OSError) as e:
        sys.exit(str(e))
    if not segmentos:
        sys.exit(f"{args.segmentos} no tiene ninguna fila con gloss.")

    print(f"{len(segmentos)} sena(s) en {args.segmentos}:")
    for s in segmentos:
        cat_txt = f"  ·  {s['categoria']}" if s["categoria"] else ""
        print(f"  {s['inicio']:>7.1f}s - {s['fin']:>7.1f}s  ->  {s['gloss']} ({s['espanol']}){cat_txt}")

    if args.seco:
        print("\n(--seco: no se descargo, recorto ni subio nada)")
        return

    if not os.path.exists(args.pose_model):
        sys.exit(f"no encuentro el modelo de pose en {args.pose_model} (ver CORRER.md)")
    if not os.path.exists(args.hand_model):
        sys.exit(f"no encuentro el modelo de manos en {args.hand_model} (ver CORRER.md)")

    load_dotenv()

    with tempfile.TemporaryDirectory(prefix="univoz_segmentos_") as tmp:
        video_local = descargar_si_es_link(args.video, tmp)
        if not os.path.exists(video_local):
            sys.exit(f"no existe el video: {video_local}")

        print("\nConectando a la base y cargando MediaPipe (una sola vez para todos los tramos)...")
        conn = db.conectar()
        extractor = ExtractorLandmarks(args.pose_model, args.hand_model)
        resultados = []
        try:
            for i, s in enumerate(segmentos, start=1):
                print(f"\n[{i}/{len(segmentos)}] {s['gloss']} ({s['inicio']:.1f}s - {s['fin']:.1f}s)")
                clip = os.path.join(tmp, f"{s['gloss']}_{i:03d}.mp4")
                try:
                    n = recortar_segmento(video_local, clip, s["inicio"], s["fin"])
                    if n == 0:
                        raise ValueError(
                            "el tramo quedo vacio -- revisa que inicio/fin esten "
                            "dentro de la duracion del video"
                        )
                    r = ingest_un_video(
                        conn, extractor,
                        video_path=clip, gloss=s["gloss"], espanol=s["espanol"],
                        categoria=s["categoria"], manos=args.manos,
                        es_estatica=args.es_estatica, usa_no_manuales=args.usa_no_manuales,
                        signer=args.signer, mano_dominante=args.mano_dominante,
                        espejo=args.espejo, generar_espejo=args.generar_espejo,
                        mascara=mascara,
                        aprobar=args.aprobar,
                    )
                    conn.commit()
                    print(f"  ok - {r['n_frames']} frames, calidad {r['quality_score']:.0%}, {r['estado']}")
                    resultados.append({
                        "gloss": s["gloss"], "espanol": s["espanol"], "ok": True,
                        "sample_id": r["sample_id"], "calidad": round(r["quality_score"], 3),
                        "estado": r["estado"],
                    })
                except Exception as e:
                    conn.rollback()
                    print(f"  FALLO: {e}")
                    resultados.append({"gloss": s["gloss"], "espanol": s["espanol"], "ok": False, "error": str(e)})
                finally:
                    if os.path.exists(clip):
                        os.remove(clip)
        finally:
            extractor.cerrar()
            conn.close()

    ok = [r for r in resultados if r["ok"]]
    fallidos = [r for r in resultados if not r["ok"]]
    print(f"\nListo: {len(ok)}/{len(resultados)} subidos.")
    if fallidos:
        print(f"{len(fallidos)} no se subieron:")
        for r in fallidos:
            print(f"  {r['gloss']}: {r['error']}")
    print(
        "\nQuedaron 'pendiente' (salvo que hayas usado --aprobar). Revisalas y "
        "aprobalas (INGESTA.md paso 7) y despues corre "
        "'python tools/exportar_paquete.py' para que entren al paquete de la app."
    )

    if args.csv_resumen:
        campos = ["gloss", "espanol", "ok", "sample_id", "calidad", "estado", "error"]
        with open(args.csv_resumen, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=campos, extrasaction="ignore")
            w.writeheader()
            w.writerows(resultados)
        print(f"Resumen escrito en {args.csv_resumen}")


if __name__ == "__main__":
    main()
