"""El CSV de tramos (<video>.segmentos.csv), en un solo lugar.

Lo escriben varias herramientas (subtitulos.py, voz.py, ocr_rotulos.py, la
pagina de revision) y lo lee ingest_segmentos.py. Tener el formato aqui
evita que cada una lo escriba un poco distinto.

Columnas:
  n, inicio_s, fin_s, duracion_s, palabra, categoria   <- las de siempre
  fuente      de donde salio la palabra: subtitulos | texto | voz | imagen | manual
  confianza   0 a 1 (vacia si la fuente no la da)
  aprobada    si | no | vacia (= todavia sin revisar)

Las tres ultimas son nuevas. ingest_segmentos.py las ignora salvo que se le
pase --solo-aprobadas, asi que un CSV viejo (sin ellas) sigue funcionando.
"""

import csv
import os

COLUMNAS = ["n", "inicio_s", "fin_s", "duracion_s", "palabra", "categoria",
            "fuente", "confianza", "aprobada"]


def ruta_csv(video):
    return os.path.splitext(video)[0] + ".segmentos.csv"


def escribir(video, filas):
    """filas: lista de dicts con inicio_s, fin_s, palabra y, opcionales,
    categoria / fuente / confianza / aprobada. n y duracion_s se calculan."""
    ruta = ruta_csv(video)
    # utf-8-sig: Excel solo abre bien los acentos si el archivo lleva BOM.
    with open(ruta, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(COLUMNAS)
        for k, fila in enumerate(filas, start=1):
            a = float(fila["inicio_s"])
            b = float(fila["fin_s"])
            conf = fila.get("confianza")
            w.writerow([
                k, round(a, 2), round(b, 2), round(b - a, 2),
                fila.get("palabra", ""), fila.get("categoria") or "",
                fila.get("fuente") or "",
                "" if conf in (None, "") else round(float(conf), 2),
                fila.get("aprobada") or "",
            ])
    return ruta


def normalizar_tramos(tramos, min_dur=1.0, duracion_video=None):
    """Arregla tramos [(inicio, fin, texto, conf)] para que se puedan ver:

    - ninguno dura menos de min_dur (una sena no cabe en 0.3 s);
    - si dos se pisan, el corte pasa por la mitad del traslape;
    - nada sale del video.
    """
    t = sorted(tramos, key=lambda x: x[0])
    out = []
    for a, b, texto, conf in t:
        if b - a < min_dur:
            c = (a + b) / 2
            a, b = c - min_dur / 2, c + min_dur / 2
        a = max(0.0, a)
        if duracion_video:
            b = min(b, duracion_video)
        out.append([a, b, texto, conf])
    for i in range(1, len(out)):
        if out[i][0] < out[i - 1][1]:
            m = (out[i][0] + out[i - 1][1]) / 2
            out[i - 1][1] = m
            out[i][0] = m
    return [tuple(x) for x in out if x[1] > x[0]]
