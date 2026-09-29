#!/usr/bin/env python3
"""Parte un video de diccionario (muchas senas seguidas, con el nombre de
cada una escrito en pantalla) en un segmento por sena, detectando CUANDO
CAMBIA el rotulo -- sin leer que dice.

Por que no OCR: para cortar solo hace falta saber DONDE cambia el texto, no
que texto es. Detectar el cambio es mucho mas confiable que leerlo, y la
palabra la pones vos despues en el CSV, que ademas te obliga a mirar el
video y no confiar en una lectura automatica.

Salidas (las tres al lado del video, salvo que uses --salida):
  <video>.segmentos.csv   segmentos detectados, con la columna `palabra`
                          VACIA para que la llenes vos
  <video>.segmentos.png   hoja de contactos: un fotograma de cada segmento,
                          numerado igual que el CSV, para saber que escribir
  <video>.perfil.png      grafico de la senal detectada y los cortes, para
                          ajustar umbrales si la deteccion salio mal

Uso tipico (dos pasadas):

  1) Ver donde cae la ROI del rotulo y si tapa bien el recuadro chico:
       python tools/segmentar_video.py --video "..." --solo-roi

  2) Detectar y generar el CSV:
       python tools/segmentar_video.py --video "..." \\
           --mascara 0.70,0.00,1.00,0.55

  3) Abris el .segmentos.png, llenas la columna `palabra` del CSV, y subis
     con tools/ingest_segmentos.py

LA ROI: es el rectangulo donde aparece el rotulo, en fracciones del frame
(x0,y0,x1,y1 de 0 a 1). El default esta pensado para el alfabeto de la SEP
(letra grande a la derecha del cuerpo). Si tu video pone el texto en otro
lado, mirala con --solo-roi y ajustala con --roi.

LA MASCARA: rectangulo que se IGNORA al medir (y que conviene tapar tambien
en la ingesta). Sirve para el recuadro chico tipo "picture in picture" que
traen muchos videos de diccionario: si no se tapa, MediaPipe detecta la mano
de ese recuadro ademas de la principal y los landmarks salen mezclados.
"""

import argparse
import csv
import math
import os
import sys

import cv2
import numpy as np

# Medido sobre el alfabeto de la SEP: la letra grande cae a la derecha del
# cuerpo, y la persona (con el brazo levantado) nunca pasa de ~x=0.45.
# El borde derecho se corta en 0.655 para no rozar el recuadro chico, que
# arranca en ~0.669.
ROI_DEFAULT = "0.50,0.18,0.655,0.60"
# El recuadro chico de ese mismo video, pegado al borde derecho. Empieza en
# 0.66 (antes del borde real del recuadro) para taparlo entero, marco incluido.
MASCARA_SEP = "0.66,0.06,1.00,0.90"


def guardar_imagen(path, img):
    """cv2.imwrite() no escribe bien en rutas con acentos o ñ en Windows:
    deja el nombre con caracteres rotos, o directamente no escribe. Codificar
    en memoria y escribir con open() evita el problema."""
    ext = os.path.splitext(path)[1] or ".png"
    ok, buf = cv2.imencode(ext, img)
    if not ok:
        return False
    with open(path, "wb") as f:
        f.write(buf.tobytes())
    return True


def parse_rect(texto, nombre):
    """'x0,y0,x1,y1' en fracciones -> tupla de 4 floats."""
    try:
        partes = [float(p) for p in texto.split(",")]
    except ValueError:
        sys.exit(f"--{nombre} tiene que ser 4 numeros separados por comas, ej. 0.55,0.02,0.78,0.48")
    if len(partes) != 4:
        sys.exit(f"--{nombre} tiene que tener exactamente 4 numeros (x0,y0,x1,y1)")
    x0, y0, x1, y1 = partes
    if not (0 <= x0 < x1 <= 1 and 0 <= y0 < y1 <= 1):
        sys.exit(f"--{nombre}: los valores van de 0 a 1 y x0<x1, y0<y1")
    return x0, y0, x1, y1


def a_pixeles(rect, ancho, alto):
    x0, y0, x1, y1 = rect
    return (int(x0 * ancho), int(y0 * alto), int(x1 * ancho), int(y1 * alto))


def hhmmss(s):
    return f"{int(s // 60)}:{s % 60:05.2f}"


def medir(video, roi, mascara, escala=64):
    """Recorre el video y devuelve (fps, n_frames, tinta, dif).

    tinta[i]: cuanta "tinta" (pixeles que se salen del fondo) hay en la ROI
              del frame i, de 0 a 1. Cuando el rotulo se desvanece entre una
              sena y la siguiente, esto baja.
    dif[i]:   cuanto cambio la ROI entre el frame i-1 y el i, de 0 a 1.
    """
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        sys.exit(f"OpenCV no pudo abrir el video: {video}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 0
    if fps <= 0:
        cap.release()
        sys.exit("el video no reporta fps: OpenCV lo abrio pero no lo puede leer bien")

    tinta, dif = [], []
    previa = None
    rx0 = ry0 = rx1 = ry1 = None
    n = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if rx0 is None:
            alto, ancho = frame.shape[:2]
            rx0, ry0, rx1, ry1 = a_pixeles(roi, ancho, alto)
            if mascara:
                mx0, my0, mx1, my1 = a_pixeles(mascara, ancho, alto)
            else:
                mx0 = my0 = mx1 = my1 = None

        if mx0 is not None:
            # Tapar la mascara ANTES de recortar la ROI, por si se solapan.
            frame = frame.copy()
            frame[my0:my1, mx0:mx1] = 255

        recorte = frame[ry0:ry1, rx0:rx1]
        gris = cv2.cvtColor(recorte, cv2.COLOR_BGR2GRAY)
        chica = cv2.resize(gris, (escala, escala)).astype(np.float32) / 255.0

        # "Tinta": que tan lejos esta cada pixel del tono de fondo. El fondo
        # de estos videos es claro, asi que se mide contra el percentil alto
        # del propio recorte -- asi funciona igual con fondo blanco, crema o
        # gris, sin tener que configurar el color.
        fondo = np.percentile(chica, 90)
        tinta.append(float(np.mean(np.abs(chica - fondo) > 0.15)))

        dif.append(0.0 if previa is None else float(np.mean(np.abs(chica - previa))))
        previa = chica
        n += 1

    cap.release()
    return fps, n, np.array(tinta), np.array(dif)


def umbral_sobre_piso(senal, margen_min=0.08, sigmas=5.0):
    """Umbral para decidir "hay rotulo", medido DESDE EL PISO de la senal.

    La tentacion es partir la senal por la mitad entre su minimo y su maximo,
    o usar Otsu. Las dos fallan aca, por la misma razon: suponen dos grupos
    de tamano parecido y repartidos de forma pareja, y esta senal no es asi.

      - La ALTURA de la meseta cambia mucho segun el rotulo: una I marca la
        mitad de tinta que una M. Un umbral puesto "al medio" deja afuera
        justo las palabras de trazo fino.
      - El rotulo esta en pantalla mucho mas tiempo del que no esta (2.5s
        contra 0.6s), asi que cualquier metodo que pese por cantidad de
        frames se corre hacia arriba.
      - Una portada o un fundido que llene la ROI marca casi 1.0 y estira el
        rango hasta donde no vive ningun dato.

    Lo que SI es estable es el piso: cuando no hay rotulo, la ROI es fondo
    liso y la medida cae a casi cero, con muy poca variacion. Entonces la
    pregunta correcta no es "esta mas cerca del techo o del piso", sino
    "esta claramente por encima del fondo". Eso no depende de que tan alta
    sea la meseta, que es justo lo que variaba.
    """
    piso = float(np.percentile(senal, 5))
    # Percentil 75, no 95: en un video corto una portada de varios segundos
    # se cuela en el 95 y estira el rango hasta 1.0, lo que empuja el umbral
    # por encima de las mesetas de rotulo fino. El 75 cae dentro de las
    # mesetas, que es la referencia que queremos.
    techo = float(np.percentile(senal, 75))
    rango = max(techo - piso, 1e-6)

    # Ruido, estimado con las diferencias entre frames consecutivos en vez
    # de con la dispersion de los valores: la senal es plana casi todo el
    # tiempo (dentro de un tramo y dentro de un hueco), asi que la MEDIANA
    # de esas diferencias mide ruido y nada mas -- los pocos saltos de
    # verdad, al ser pocos, no mueven una mediana. Medir la dispersion de
    # los valores, en cambio, mezcla el ruido con la altura de las mesetas.
    d = np.abs(np.diff(senal))
    ruido = float(np.median(d)) * 1.4826 / math.sqrt(2) if len(d) else 0.0

    return piso + max(margen_min * rango, sigmas * ruido)


def segmentos_por_huecos(tinta, fps, umbral, min_dur, min_hueco):
    """Corta donde el rotulo DESAPARECE (la senal mas limpia: si el video
    hace fade entre sena y sena, el hueco es inequivoco).

    Devuelve [(frame_inicio, frame_fin)] de los tramos CON rotulo.
    """
    con_texto = tinta > umbral
    min_hueco_f = max(1, int(min_hueco * fps))
    min_dur_f = max(1, int(min_dur * fps))

    tramos = []
    inicio = None
    hueco = 0
    for i, hay in enumerate(con_texto):
        if hay:
            if inicio is None:
                inicio = i
            hueco = 0
        else:
            if inicio is not None:
                hueco += 1
                if hueco >= min_hueco_f:
                    fin = i - hueco
                    if fin - inicio >= min_dur_f:
                        tramos.append((inicio, fin))
                    inicio = None
                    hueco = 0
    if inicio is not None and len(con_texto) - inicio >= min_dur_f:
        tramos.append((inicio, len(con_texto) - 1))
    return tramos


def segmentos_por_saltos(dif, fps, min_dur, n_esperado=None):
    """Plan B: cuando el rotulo NO desaparece entre senas (cambia de golpe),
    corta en los picos de cambio. Menos confiable -- un movimiento grande de
    la persona dentro de la ROI tambien hace pico."""
    min_dur_f = max(1, int(min_dur * fps))
    orden = np.argsort(dif)[::-1]

    cortes = []
    for i in orden:
        if dif[i] <= 0:
            break
        if all(abs(int(i) - c) >= min_dur_f for c in cortes):
            cortes.append(int(i))
        if n_esperado and len(cortes) >= n_esperado - 1:
            break
    cortes.sort()

    limites = [0] + cortes + [len(dif) - 1]
    return [(limites[k], limites[k + 1] - 1) for k in range(len(limites) - 1)]


def recortar_por_quietud(video, tramos, fps, margen=0.15):
    """Le saca a cada tramo la quietud DEL PRINCIPIO, no la del final.

    Importa porque la ingesta remuestrea todo a un numero fijo de frames: si
    el tramo trae dos segundos de la persona quieta antes de empezar, esos
    frames muertos se comen parte de la sena real y la muestra queda peor.

    Solo el principio, a proposito. Muchas senas -- casi todas las letras
    del alfabeto -- terminan QUIETAS: la mano sube, se queda sosteniendo la
    forma, y recien despues baja. Recortar tambien por el final le cortaria
    justo la parte sostenida, que es la sena. La quietud del principio, en
    cambio, es siempre la persona esperando, y esa sobra.
    """
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        return tramos

    ajustados = []
    for (a, b) in tramos:
        cap.set(cv2.CAP_PROP_POS_FRAMES, a)
        movimiento = []
        previa = None
        for _ in range(b - a + 1):
            ok, frame = cap.read()
            if not ok:
                break
            gris = cv2.resize(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY), (96, 96)).astype(np.float32) / 255.0
            movimiento.append(0.0 if previa is None else float(np.mean(np.abs(gris - previa))))
            previa = gris
        if len(movimiento) < 4:
            ajustados.append((a, b))
            continue
        mov = np.array(movimiento)
        umbral = mov.max() * margen
        activos = np.where(mov > umbral)[0]
        if len(activos) < 2:
            ajustados.append((a, b))
            continue
        # Un par de frames de aire antes del primer movimiento, para no
        # cortar el arranque del gesto. El final se deja donde estaba.
        aire = max(1, int(0.1 * fps))
        ini = a + max(0, int(activos[0]) - aire)
        ajustados.append((ini, b) if b > ini else (a, b))
    cap.release()
    return ajustados


def hoja_de_segmentos(video, tramos, fps, salida, columnas=5, ancho=330, mascara=None):
    """Un fotograma del medio de cada segmento, numerado igual que el CSV."""
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        return False
    minis = []
    for k, (a, b) in enumerate(tramos, start=1):
        cap.set(cv2.CAP_PROP_POS_FRAMES, (a + b) // 2)
        ok, frame = cap.read()
        if not ok:
            continue
        if mascara:
            alto_f, ancho_f = frame.shape[:2]
            mx0, my0, mx1, my1 = a_pixeles(mascara, ancho_f, alto_f)
            cv2.rectangle(frame, (mx0, my0), (mx1, my1), (0, 0, 255), 3)
            cv2.line(frame, (mx0, my0), (mx1, my1), (0, 0, 255), 2)
        alto = int(frame.shape[0] * ancho / frame.shape[1])
        chica = cv2.resize(frame, (ancho, alto))
        etiqueta = f"#{k}  {hhmmss(a / fps)}-{hhmmss(b / fps)}"
        cv2.putText(chica, etiqueta, (8, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 0), 4)
        cv2.putText(chica, etiqueta, (8, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 1)
        minis.append(chica)
    cap.release()
    if not minis:
        return False

    filas = []
    for i in range(0, len(minis), columnas):
        grupo = minis[i:i + columnas]
        while len(grupo) < columnas:
            grupo.append(np.zeros_like(minis[0]))
        filas.append(np.hstack(grupo))
    guardar_imagen(salida, np.vstack(filas))
    return True


def grafico_perfil(tinta, dif, tramos, fps, umbral, salida):
    """Grafico de las dos senales con los cortes marcados. Es la forma de
    ver POR QUE la deteccion salio como salio, en vez de adivinar umbrales."""
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return False

    t = np.arange(len(tinta)) / fps
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 6), sharex=True)

    ax1.plot(t, tinta, lw=1)
    ax1.axhline(umbral, color="red", ls="--", lw=1, label=f"umbral tinta = {umbral:.3f}")
    ax1.set_ylabel("tinta en la ROI")
    ax1.legend(loc="upper right", fontsize=8)

    ax2.plot(t, dif, lw=1, color="tab:orange")
    ax2.set_ylabel("cambio entre frames")
    ax2.set_xlabel("segundos")

    for k, (a, b) in enumerate(tramos, start=1):
        for ax in (ax1, ax2):
            ax.axvspan(a / fps, b / fps, color="tab:green", alpha=0.15)
        ax1.text((a + b) / 2 / fps, ax1.get_ylim()[1] * 0.9, str(k),
                 ha="center", fontsize=7)

    fig.tight_layout()
    fig.savefig(salida, dpi=110)
    plt.close(fig)
    return True


def rellenar_glosas(ruta):
    """Completa la columna 'gloss' a partir de 'espanol', con a_glosa().

    Escribir la glosa a mano es donde se cuela el error: hay que acordarse
    de que va en mayusculas, sin acentos, con _ en vez de espacios, y de
    que la ñ va NN para no chocar con la N. La funcion que usa la app ya
    sabe todo eso, asi que mejor preguntarle a ella.
    """
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        from glosa import a_glosa
    except ImportError:
        sys.exit("no encuentro tools/glosa.py al lado de este script")

    with open(ruta, encoding="utf-8-sig", newline="") as f:
        filas = list(csv.DictReader(f))
    if not filas:
        sys.exit(f"{ruta} no tiene filas")
    campos = list(filas[0].keys())
    if "espanol" not in campos:
        sys.exit(f"a {ruta} le falta la columna 'espanol'")
    if "gloss" not in campos:
        campos.insert(campos.index("espanol"), "gloss")

    cambiadas = 0
    for fila in filas:
        palabra = (fila.get("espanol") or "").strip()
        if not palabra:
            continue
        g = a_glosa(palabra)
        if g and g != (fila.get("gloss") or "").strip():
            fila["gloss"] = g
            cambiadas += 1

    with open(ruta, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=campos, extrasaction="ignore")
        w.writeheader()
        w.writerows(filas)

    print(f"{ruta}: {cambiadas} glosa(s) completada(s)")
    for fila in filas:
        if (fila.get("espanol") or "").strip():
            print(f"  {fila['espanol']:<14} -> {fila.get('gloss','')}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", required=True)
    ap.add_argument("--roi", default=ROI_DEFAULT,
                    help=f"rectangulo del rotulo, x0,y0,x1,y1 en fracciones (default {ROI_DEFAULT})")
    ap.add_argument("--mascara",
                    help="rectangulo a ignorar, ej. el recuadro chico: x0,y0,x1,y1 en fracciones")
    ap.add_argument("--mascara-sep", action="store_true",
                    help=f"atajo: usa la mascara del alfabeto de la SEP ({MASCARA_SEP})")
    ap.add_argument("--umbral", type=float,
                    help="cuanta tinta cuenta como 'hay rotulo' (default: automatico)")
    ap.add_argument("--min-duracion", type=float, default=1.0,
                    help="segundos minimos de un segmento (default 1.0)")
    ap.add_argument("--min-hueco", type=float, default=0.15,
                    help="segundos sin rotulo para considerarlo un corte (default 0.15)")
    ap.add_argument("--saltos", action="store_true",
                    help="plan B: cortar por picos de cambio en vez de por huecos del rotulo")
    ap.add_argument("--n-esperado", type=int,
                    help="cuantas senas esperas (solo con --saltos, ayuda a elegir los cortes)")
    ap.add_argument("--sin-recorte-quietud", action="store_true",
                    help="no achicar cada segmento a la parte con movimiento")
    ap.add_argument("--solo-roi", action="store_true",
                    help="solo guarda una imagen con la ROI y la mascara dibujadas, y termina")
    ap.add_argument("--salida", help="prefijo de los archivos de salida (default: el del video)")
    ap.add_argument("--categoria", help="categoria que se escribe en todas las filas del CSV")
    ap.add_argument(
        "--formato", choices=["gloss", "palabra"], default="gloss",
        help=(
            "que columnas lleva el CSV. 'gloss' (default): inicio,fin,gloss,espanol,"
            "categoria -- el que lee tools/ingest_video_segmentos.py. 'palabra': "
            "n,inicio_s,fin_s,duracion_s,palabra,categoria, para tools/ingest_segmentos.py."
        ),
    )
    ap.add_argument(
        "--rellenar-glosas", metavar="CSV", dest="rellenar",
        help=(
            "otro modo: no analiza el video. Toma un CSV que ya tiene la columna "
            "'espanol' escrita a mano y le completa la columna 'gloss' con la misma "
            "conversion que usa la app (a_glosa), asi no hay que acordarse de las "
            "reglas -- que 'ñ' va NN, que los acentos se caen, que los espacios son _."
        ),
    )
    args = ap.parse_args()

    if args.rellenar:
        rellenar_glosas(args.rellenar)
        return

    if not os.path.exists(args.video):
        sys.exit(f"no existe el video: {args.video}")

    roi = parse_rect(args.roi, "roi")
    texto_mascara = args.mascara or (MASCARA_SEP if args.mascara_sep else None)
    mascara = parse_rect(texto_mascara, "mascara") if texto_mascara else None
    prefijo = args.salida or os.path.splitext(args.video)[0]

    # --- modo revision: dibujar ROI y mascara sobre un frame ---
    if args.solo_roi:
        cap = cv2.VideoCapture(args.video)
        cap.set(cv2.CAP_PROP_POS_FRAMES, int((cap.get(cv2.CAP_PROP_FRAME_COUNT) or 60) * 0.3))
        ok, frame = cap.read()
        cap.release()
        if not ok:
            sys.exit("no pude leer un fotograma del video")
        alto, ancho = frame.shape[:2]
        x0, y0, x1, y1 = a_pixeles(roi, ancho, alto)
        cv2.rectangle(frame, (x0, y0), (x1, y1), (0, 200, 0), 3)
        cv2.putText(frame, "ROI del rotulo", (x0, max(24, y0 - 8)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 200, 0), 2)
        if mascara:
            mx0, my0, mx1, my1 = a_pixeles(mascara, ancho, alto)
            cv2.rectangle(frame, (mx0, my0), (mx1, my1), (0, 0, 255), 3)
            cv2.line(frame, (mx0, my0), (mx1, my1), (0, 0, 255), 2)
            cv2.putText(frame, "mascara (se tapa)", (mx0, max(24, my0 - 8)),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)
        salida = prefijo + ".roi.png"
        guardar_imagen(salida, frame)
        print(f"Listo: {salida}")
        print("Mira que el rectangulo VERDE cubra el rotulo y NADA de la persona,")
        print("y que el ROJO tape el recuadro chico entero.")
        return

    print("Midiendo el video ...")
    fps, n_frames, tinta, dif = medir(args.video, roi, mascara)
    print(f"  {n_frames} frames a {fps:.1f} fps ({n_frames / fps:.1f}s)")

    if args.saltos:
        tramos = segmentos_por_saltos(dif, fps, args.min_duracion, args.n_esperado)
        umbral = 0.0
        print(f"  modo saltos: {len(tramos)} segmento(s)")
    else:
        umbral = args.umbral if args.umbral is not None else umbral_sobre_piso(tinta)
        tramos = segmentos_por_huecos(tinta, fps, umbral, args.min_duracion, args.min_hueco)
        print(f"  umbral de tinta: {umbral:.3f}  ->  {len(tramos)} segmento(s)")
        if len(tramos) < 2:
            print("\n  OJO: casi no se detectaron cortes. Puede ser que el rotulo no")
            print("  desaparezca entre senas. Proba de nuevo con --saltos, o revisa")
            print("  la ROI con --solo-roi.")

    if tramos and not args.sin_recorte_quietud:
        print("Ajustando cada segmento a la parte con movimiento ...")
        tramos = recortar_por_quietud(args.video, tramos, fps)

    if not tramos:
        sys.exit("no se detecto ningun segmento. Revisa la ROI con --solo-roi.")

    csv_path = prefijo + ".segmentos.csv"
    with open(csv_path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        if args.formato == "gloss":
            # El que consume tools/ingest_video_segmentos.py.
            w.writerow(["inicio", "fin", "gloss", "espanol", "categoria"])
            for (a, b) in tramos:
                w.writerow([round(a / fps, 2), round(b / fps, 2), "", "", args.categoria or ""])
        else:
            w.writerow(["n", "inicio_s", "fin_s", "duracion_s", "palabra", "categoria"])
            for k, (a, b) in enumerate(tramos, start=1):
                w.writerow([k, round(a / fps, 2), round(b / fps, 2),
                            round((b - a) / fps, 2), "", args.categoria or ""])

    png_path = prefijo + ".segmentos.png"
    hoja_de_segmentos(args.video, tramos, fps, png_path, mascara=mascara)

    perfil_path = prefijo + ".perfil.png"
    tiene_grafico = grafico_perfil(tinta, dif, tramos, fps, umbral, perfil_path)

    print(f"\n{len(tramos)} segmento(s):")
    for k, (a, b) in enumerate(tramos, start=1):
        print(f"  #{k:<3} {hhmmss(a / fps)} - {hhmmss(b / fps)}   ({(b - a) / fps:.2f}s)")

    print(f"\n  {csv_path}")
    print(f"  {png_path}")
    if tiene_grafico:
        print(f"  {perfil_path}")

    print(
        "\nAhora: abri el .segmentos.png, y en el CSV llena la columna `palabra`\n"
        "con lo que dice cada segmento (la fila #N es el fotograma #N).\n"
        "Borra las filas que no sean una sena (intro, creditos, transiciones).\n"
        "Despues: python tools/ingest_segmentos.py --video \"...\" --csv \"...\""
    )


if __name__ == "__main__":
    main()
