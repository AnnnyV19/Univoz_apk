#!/usr/bin/env python3
"""Sube MUCHAS senas que viven dentro de UN SOLO video, usando el CSV de
tramos que dejo tools/segmentar_video.py.

Es la tercera forma de subir senas, y comparte ingest_un_video() con las
otras dos (un archivo suelto: ingest_video.py; una carpeta entera:
ingest_carpeta.py), asi que un cambio en como se guarda una muestra aplica a
las tres por igual.

Flujo completo:

  1) python tools/segmentar_video.py --video "diccionario.mp4" --mascara-sep
        -> deja diccionario.segmentos.csv y diccionario.segmentos.png

  2) Abris el .png, y en el CSV llenas la columna `palabra` con lo que dice
     cada tramo. Borras las filas que no sean una sena (portada, creditos).

  3) python tools/ingest_segmentos.py --video "diccionario.mp4" \\
         --csv "diccionario.segmentos.csv" --mascara-sep --signer TuNombre

Antes de subir nada, revisa el plan con --seco: no toca la base ni corre
MediaPipe, solo imprime que glosa le va a tocar a cada tramo.

EL VIDEO SE SUBE UNA SOLA VEZ. Las 29 muestras de un alfabeto salen del
mismo archivo, asi que subirlo 29 veces a Supabase Storage seria tirar
ancho de banda y cuota. Cada muestra guarda el mismo link con su tramo
detras (#t=inicio,fin), que ademas la mayoria de los reproductores entiende:
al abrirlo arranca justo en esa sena.
"""

import argparse
import csv
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import db  # noqa: E402
from dotenv import load_dotenv  # noqa: E402
from extraer_landmarks import ExtractorLandmarks  # noqa: E402
from glosa import a_glosa  # noqa: E402
from ingest_video import ingest_un_video  # noqa: E402
from segmentar_video import MASCARA_SEP, parse_rect  # noqa: E402
from storage import subir_video  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "android", "app", "src", "main", "assets")


_SI = ("si", "sí", "s", "1", "true", "x")


def leer_csv(ruta, solo_aprobadas=False):
    """Devuelve [(n, inicio, fin, palabra, categoria)] de las filas que
    tienen palabra. Las filas sin palabra se saltan en silencio: son las que
    la persona dejo vacias a proposito (portada, creditos, transiciones).

    Con solo_aprobadas, ademas, solo pasan las filas cuya columna `aprobada`
    dice "si" (la que marca la pagina de revision viendo cada clip). Las que
    estan sin revisar o descartadas no se suben."""
    filas = []
    sin_revisar = 0
    with open(ruta, encoding="utf-8-sig", newline="") as f:
        lector = csv.DictReader(f)
        necesarias = {"inicio_s", "fin_s", "palabra"}
        if solo_aprobadas:
            necesarias.add("aprobada")
        faltan = necesarias - set(lector.fieldnames or [])
        if faltan:
            sys.exit(
                f"al CSV le faltan columnas: {', '.join(sorted(faltan))}\n"
                "Tiene que ser el que genera tools/segmentar_video.py."
            )
        for i, fila in enumerate(lector, start=2):
            palabra = (fila.get("palabra") or "").strip()
            if not palabra:
                continue
            if solo_aprobadas and (fila.get("aprobada") or "").strip().lower() not in _SI:
                sin_revisar += 1
                continue
            try:
                inicio = float(fila["inicio_s"])
                fin = float(fila["fin_s"])
            except (TypeError, ValueError):
                print(f"  linea {i}: inicio_s/fin_s no son numeros, la salteo")
                continue
            if fin <= inicio:
                print(f"  linea {i}: fin_s no es mayor que inicio_s, la salteo")
                continue
            categoria = (fila.get("categoria") or "").strip() or None
            filas.append((fila.get("n") or str(i), inicio, fin, palabra, categoria))
    if solo_aprobadas and sin_revisar:
        print(f"  {sin_revisar} fila(s) con palabra NO se suben: sin aprobar o descartadas")
    return filas


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", required=True, help="el video que contiene todas las senas")
    ap.add_argument("--csv", help="el .segmentos.csv (default: el del video)")
    ap.add_argument("--mascara", help="rectangulo a tapar: x0,y0,x1,y1 en fracciones")
    ap.add_argument("--mascara-sep", action="store_true",
                    help=f"atajo: la mascara del alfabeto de la SEP ({MASCARA_SEP})")
    ap.add_argument("--categoria", help="categoria por defecto para las filas que no traen una")
    ap.add_argument("--manos", type=int, choices=[1, 2], default=1)
    ap.add_argument("--es-estatica", action="store_true")
    ap.add_argument("--usa-no-manuales", action="store_true")
    ap.add_argument("--signer", help="quien aparece en el video, para no mezclar train/test")
    ap.add_argument("--mano", choices=["izquierda", "derecha"], dest="mano_dominante")
    ap.add_argument("--espejo", action="store_true", help="si el video quedo espejeado")
    ap.add_argument("--aprobar", action="store_true",
                    help="deja las muestras YA aprobadas en la base (si no, quedan pendientes)")
    ap.add_argument("--solo-aprobadas", action="store_true", dest="solo_aprobadas",
                    help="sube solo las filas con aprobada=si en el CSV (la revision "
                         "que se hace en la pagina de ingesta)")
    ap.add_argument("--generar-espejo", action="store_true", dest="generar_espejo")
    ap.add_argument("--sin-subir-video", action="store_true",
                    help="no subir el archivo a Supabase Storage (igual guarda el tramo)")
    ap.add_argument("--seco", action="store_true", help="muestra el plan sin tocar la base ni MediaPipe")
    ap.add_argument("--csv-resumen", help="escribe el resumen en este CSV")
    ap.add_argument("--pose-model", default=os.path.join(ASSETS, "pose_landmarker_lite.task"))
    ap.add_argument("--hand-model", default=os.path.join(ASSETS, "hand_landmarker.task"))
    args = ap.parse_args()

    if not os.path.exists(args.video):
        sys.exit(f"no existe el video: {args.video}")

    ruta_csv = args.csv or (os.path.splitext(args.video)[0] + ".segmentos.csv")
    if not os.path.exists(ruta_csv):
        sys.exit(
            f"no existe el CSV: {ruta_csv}\n"
            "Generalo primero con tools/segmentar_video.py"
        )

    texto_mascara = args.mascara or (MASCARA_SEP if args.mascara_sep else None)
    mascara = parse_rect(texto_mascara, "mascara") if texto_mascara else None

    filas = leer_csv(ruta_csv, args.solo_aprobadas)
    if not filas and args.solo_aprobadas:
        sys.exit(
            "ninguna fila esta aprobada: no hay nada que subir.\n"
            "Revisa los clips en la pagina y aprueba (con la palomita) las buenas."
        )
    if not filas:
        sys.exit(
            f"ninguna fila de {ruta_csv} tiene algo en la columna `palabra`.\n"
            "Llenala con lo que dice cada tramo (mira el .segmentos.png) y volve a correr."
        )

    planeados = []
    for n, inicio, fin, palabra, categoria in filas:
        gloss = a_glosa(palabra)
        if not gloss:
            print(f"  #{n}: '{palabra}' no da ninguna glosa valida, la salteo")
            continue
        planeados.append((n, inicio, fin, gloss, palabra, categoria or args.categoria))

    print(f"{len(planeados)} sena(s) en {os.path.basename(ruta_csv)}:")
    for n, inicio, fin, gloss, palabra, categoria in planeados:
        cat = f"  ·  {categoria}" if categoria else ""
        # Una sena dura uno o dos segundos. Mas de 10 casi siempre es un
        # corte que se paso (o dos senas pegadas): mejor decirlo antes.
        largo = f"  <-- OJO: dura {fin - inicio:.0f}s, ¿esta bien cortada?" if fin - inicio > 10 else ""
        print(f"  #{n:<4} {inicio:7.2f}s - {fin:7.2f}s  ->  {gloss} ({palabra}){cat}{largo}")

    # Dos tramos con la misma glosa no es un error -- son dos tomas de la
    # misma sena, que es justo lo que conviene tener. Pero si NO era la
    # intencion (dos filas mal etiquetadas), pasa desapercibido, asi que se
    # avisa.
    glosas = [p[3] for p in planeados]
    repetidas = sorted({g for g in glosas if glosas.count(g) > 1})
    if repetidas:
        print(f"\n  aviso: {len(repetidas)} glosa(s) aparecen mas de una vez: {', '.join(repetidas)}")
        print("  (esta bien si son varias tomas de la misma sena; revisalo si no)")

    if args.seco:
        print("\n(--seco: no se proceso nada)")
        return

    if not os.path.exists(args.pose_model):
        sys.exit(f"no encuentro el modelo de pose en {args.pose_model} (ver CORRER.md)")
    if not os.path.exists(args.hand_model):
        sys.exit(f"no encuentro el modelo de manos en {args.hand_model} (ver CORRER.md)")

    load_dotenv()

    # El video se sube UNA vez para todas las muestras (ver el docstring).
    base_uri = os.path.basename(args.video)
    if not args.sin_subir_video:
        print("\nSubiendo el video (una sola vez para todos los tramos)...")
        nombre_remoto = f"_diccionarios/{uuid.uuid4().hex}_{os.path.basename(args.video)}"
        subido = subir_video(args.video, nombre_remoto)
        if subido:
            base_uri = subido
            print(f"  {base_uri}")
        else:
            print("  (Supabase Storage no configurado: se guarda solo el nombre del archivo)")

    print("\nConectando a la base y cargando MediaPipe (una sola vez para todo el video)...")
    conn = db.conectar()
    extractor = ExtractorLandmarks(args.pose_model, args.hand_model)
    resultados = []
    try:
        for i, (n, inicio, fin, gloss, palabra, categoria) in enumerate(planeados, start=1):
            print(f"\n[{i}/{len(planeados)}] #{n}  {gloss}  ({inicio:.2f}s - {fin:.2f}s)")
            try:
                r = ingest_un_video(
                    conn, extractor,
                    video_path=args.video, gloss=gloss, espanol=palabra,
                    categoria=categoria, manos=args.manos,
                    es_estatica=args.es_estatica, usa_no_manuales=args.usa_no_manuales,
                    signer=args.signer, mano_dominante=args.mano_dominante,
                    espejo=args.espejo, generar_espejo=args.generar_espejo,
                    aprobar=args.aprobar,
                    desde=inicio, hasta=fin, mascara=mascara,
                    # El tramo va en el link: al abrirlo, el reproductor
                    # arranca en esta sena y no al principio del video.
                    video_uri_fijo=f"{base_uri}#t={inicio:.2f},{fin:.2f}",
                )
                conn.commit()
                print(f"  ok - {r['n_frames']} frames, calidad {r['quality_score']:.0%}, {r['estado']}")
                resultados.append({
                    "n": n, "gloss": gloss, "palabra": palabra, "ok": True,
                    "sample_id": r["sample_id"], "calidad": round(r["quality_score"], 3),
                    "n_frames": r["n_frames"], "estado": r["estado"],
                })
            except Exception as e:
                conn.rollback()
                print(f"  FALLO: {e}")
                resultados.append({"n": n, "gloss": gloss, "ok": False, "error": str(e)})
    finally:
        extractor.cerrar()
        conn.close()

    ok = [r for r in resultados if r["ok"]]
    fallidos = [r for r in resultados if not r["ok"]]
    print(f"\nListo: {len(ok)}/{len(resultados)} subidas.")
    if fallidos:
        print(f"{len(fallidos)} no se subieron:")
        for r in fallidos:
            print(f"  #{r['n']} {r['gloss']}: {r['error']}")

    # La calidad baja es la senal de que un tramo quedo mal cortado o que la
    # persona no se vio bien: vale mas revisarlo ahora que descubrirlo
    # cuando el reconocimiento falle.
    flojas = sorted((r for r in ok if r["calidad"] < 0.8), key=lambda r: r["calidad"])
    if flojas:
        print(f"\n{len(flojas)} con calidad por debajo del 80% (revisalas antes de aprobar):")
        for r in flojas:
            print(f"  #{r['n']} {r['gloss']}: {r['calidad']:.0%} ({r['n_frames']} frames)")

    print(
        "\nQuedaron 'pendiente' (salvo que hayas usado --aprobar). Revisalas y "
        "aprobalas (INGESTA.md paso 7) y despues corre "
        "'python tools/exportar_paquete.py' para que entren al paquete de la app."
    )

    if args.csv_resumen:
        campos = ["n", "gloss", "palabra", "ok", "sample_id", "calidad", "n_frames", "estado", "error"]
        with open(args.csv_resumen, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=campos, extrasaction="ignore")
            w.writeheader()
            w.writerows(resultados)
        print(f"Resumen escrito en {args.csv_resumen}")


if __name__ == "__main__":
    main()
