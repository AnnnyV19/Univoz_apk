#!/usr/bin/env python3
"""Importa el ALFABETO ESTATICO de la LSM (solo forma de mano) al diccionario.

Dataset: "A comprehensive dataset of static and dynamic signs for the Mexican Sign Language
alphabet" (CICESE, Data in Brief 66:112887, 2026), Zenodo 10.5281/zenodo.10067509, CC BY 4.0.
279,716 JPEG de 360 x 360 (recortes de la mano derecha sobre fondo verde, cuadros de video a
60 fps), 20 personas, letras A-I, L-P, R-U, W, Y. Tres grupos de variacion por letra:
  A (baja)  = 1 video de 3 s con giros suaves (~30 grados)   <- el que se usa por defecto
  B (media) = 3 videos de 1 s (giro en cada eje)
  C (alta)  = 1 video de 3 s con movimientos amplios
Cada grupo viene partido en train (18 personas) y test (2); aqui se usan las 20.

POR QUE NO LO HACE importar_dataset_lsm.py: los recortes no traen hombros, y sign_norm
descarta todo cuadro sin hombros. Este script hace el camino para letras ESTATICAS:

  - La FORMA de la mano (los 120 numeros que importan) sale del detector de manos igual que en
    cualquier video: relativa a la muneca y dividida por el tamano de la mano.
  - El CUERPO y la UBICACION no existen en un recorte. Se ponen los de un esqueleto neutro
    (persona de frente, hombros horizontales, muneca delante del pecho), siempre iguales. El
    reconocimiento de la app ya no usa el cuerpo (W_BODY = 0) y centra la ubicacion de cada
    secuencia, asi que en una letra estatica eso no cuenta. Estas muestras NO sirven para que
    el avatar se vea bien en el espacio: la primera plantilla de cada letra sigue siendo la del
    video del alfabeto de la SEP.
  - Los recortes son cuadrados (1:1) y el resto del sistema supone 16:9 hasta que
    curar_plantillas.py estima el aspecto. Para que la correccion de aspecto no dependa de
    adivinar, la forma se guarda "como si" el recorte estuviera dentro de un cuadro 16:9 a la
    misma escala (x y z por 9/16); curar_plantillas la devuelve a su forma real. Se apaga con
    --sin-convencion-16-9.
  - Cada TOMA = una persona haciendo una letra en un grupo (todos sus cuadros). De ella se
    toma la ventana mas quieta de ~0.5 s (la sena es estatica: lo que importa es la forma
    sostenida, no la entrada ni la salida de la mano), y se remuestrea a 32 cuadros.
  - La mano (izquierda/derecha) se decide por votacion de todos los cuadros de la toma, no
    cuadro por cuadro: un puno visto solo, sin brazo, se confunde con facilidad.

TODO entra a la base como 'pendiente' (nadie las revisa una por una) y plantillas.json no
cambia. Para usarlas:
    python tools/aprobar_dataset.py --dataset alfabeto_estatico --por-glosa 10 --seco
    python tools/aprobar_dataset.py --dataset alfabeto_estatico --por-glosa 10
(cada letra queda con hasta 10 personas distintas aprobadas; ver cobertura_muestras.py).

Uso (desde senas_core):
    python tools/importar_alfabeto_estatico.py --listar               # solo mira como esta organizado
    python tools/importar_alfabeto_estatico.py --probar 6             # 6 tomas, sin tocar la base
    python tools/importar_alfabeto_estatico.py                        # baja 4.8 GB, procesa todo
    python tools/importar_alfabeto_estatico.py --carpeta D:\\imagenes  # ya descomprimido

Si la estructura real no se reconoce (nombres de carpeta o archivo distintos a los esperados),
--listar dice que entendio de cada archivo y --patron deja decirlo a mano con una expresion
regular con grupos nombrados (?P<letra>..) (?P<sujeto>..) y opcionalmente (?P<grupo>..) sobre la
ruta relativa con '/' (sin la extension), p. ej.:
    --patron "(?P<grupo>[ABC])/(?:train|test)/(?P<letra>[A-Z])/S(?P<sujeto>\\d+)_.*"
"""

import argparse
import csv
import datetime
import json
import math
import os
import re
import shutil
import statistics
import sys
import time
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import importar_dataset_lsm as imp  # noqa: E402
import sign_norm as sn  # noqa: E402
from glosa import a_glosa  # noqa: E402

VERSION_IMPORTADOR = 1          # sube si cambia como se arma una toma (invalida el cache)

CFG = {
    "titulo": "Alfabeto LSM, letras estaticas (CICESE, recortes de mano)",
    "zenodo": "10067509",
    "archivo": "MSL-ABC.7z",
    "archivo_clave": "msl",
    "md5": None,                           # se pide a Zenodo
    "origen": "zenodo",
    "expertos": set(),
    "solo_pendientes": True,
    "categoria": "alfabeto",
    "licencia": "CC BY 4.0",
    "cita": ("Datos del articulo 'A comprehensive dataset of static and dynamic signs for the "
             "Mexican Sign Language alphabet' (CICESE, Data in Brief 66:112887, 2026). "
             "Zenodo. https://doi.org/10.5281/zenodo.10067509"),
    "credito": "(CICESE, CC BY 4.0), https://doi.org/10.5281/zenodo.10067509",
}

EXT_IMAGEN = (".jpg", ".jpeg", ".png", ".bmp")
ESPACIO_MIN_GB = 11.0
K_16_9 = 9.0 / 16.0

# ---------------------------------------------------------------------------
# Esqueleto neutro (persona de frente, camara sin espejo). Coordenadas de MediaPipe:
# imagen -> x a la derecha, y hacia abajo; mundo -> x a la derecha de la imagen, y hacia abajo,
# z creciendo al alejarse de la camara, origen en las caderas. La persona se ve de frente, asi que
# su hombro IZQUIERDO queda a la DERECHA de la imagen (igual que en un video normal).
# ---------------------------------------------------------------------------


def _esqueleto_neutro():
    pose = [[0.5, 0.5, 0.0, 0.0] for _ in range(33)]
    mundo = [[0.0, 0.0, 0.0] for _ in range(33)]

    def poner(i, xi, yi, xm, ym, zm):
        pose[i] = [xi, yi, 0.0, 0.99]
        mundo[i] = [xm, ym, zm]

    poner(11, 0.64, 0.30, 0.19, -0.45, 0.0)       # hombro izq (a la derecha de la imagen)
    poner(12, 0.36, 0.30, -0.19, -0.45, 0.0)      # hombro der
    poner(13, 0.70, 0.45, 0.24, -0.22, -0.08)     # codos
    poner(14, 0.30, 0.45, -0.24, -0.22, -0.08)
    poner(15, 0.62, 0.50, 0.10, -0.30, -0.30)     # munecas, delante del pecho
    poner(16, 0.38, 0.50, -0.10, -0.30, -0.30)
    poner(23, 0.58, 0.75, 0.09, 0.0, 0.0)         # caderas
    poner(24, 0.42, 0.75, -0.09, 0.0, 0.0)
    return pose, mundo


POSE_NEUTRA, MUNDO_NEUTRO = _esqueleto_neutro()


# ---------------------------------------------------------------------------
# 1. Que hay en la carpeta: letra, persona y grupo de cada imagen
# ---------------------------------------------------------------------------
def _norm(t):
    return unicodedata.normalize("NFC", t).strip().lower()


_LETRA_RX = re.compile(r"(?:letra|letter|sign|sena|seña|clase|class|label)?[_\- ]*([a-zñ]|ll|rr|nn)")
_SUJ_RX = re.compile(r"(?:^|[_\-\s.])(?:s|sub|subj|subject|p|part|participant|participante|"
                     r"persona|person|user|u)[_\-]?(\d{1,3})(?=$|[_\-\s.])")
# "group_A", "grupo B" y las carpetas reales del dataset: lsm-abc-A / lsm-abc-B / lsm-abc-C
_GRUPO_RX = re.compile(r"(?<![a-z0-9])(?:(?:group|grupo)[_\-\s]*|abc[_\-\s]+)([abc])(?![a-z0-9])")
_GRUPO_NIVEL = (("low", "A"), ("bajo", "A"), ("baja", "A"), ("medium", "B"), ("medio", "B"),
                ("media", "B"), ("high", "C"), ("alto", "C"), ("alta", "C"))
_PARTICION = {"train", "test", "val", "valid", "validation", "entrenamiento", "prueba", "dev"}


def _glosa_letra(t):
    return a_glosa(t) if t else None


def _letra_de_texto(texto):
    m = _LETRA_RX.fullmatch(_norm(texto))
    return _glosa_letra(m.group(1)) if m else None


def _grupo_de_texto(texto):
    t = _norm(texto)
    m = _GRUPO_RX.search(t)
    if m:
        return m.group(1).upper()
    if t in ("a", "b", "c"):
        return t.upper()
    for clave, g in _GRUPO_NIVEL:
        if re.search(r"(?<![a-z0-9])" + clave + r"(?![a-z0-9])", t):
            return g
    return None


def analizar_ruta(rel, patron=None):
    """rel: ruta relativa con '/'. Devuelve dict(letra, sujeto, grupo, particion) con None donde no
    se pudo; o None si el archivo no es una imagen."""
    base, ext = os.path.splitext(rel)
    if ext.lower() not in EXT_IMAGEN:
        return None
    partes = [unicodedata.normalize("NFC", p) for p in base.split("/")]
    stem = partes[-1]
    dirs = partes[:-1]

    if patron is not None:
        m = patron.search(base)
        if not m:
            return {"letra": None, "sujeto": None, "grupo": None, "particion": None}
        gd = m.groupdict()
        letra = _letra_de_texto(gd["letra"]) if gd.get("letra") else None
        if letra is None and gd.get("letra"):
            letra = _glosa_letra(_norm(gd["letra"]))
        suj = int(gd["sujeto"]) if gd.get("sujeto") and gd["sujeto"].isdigit() else None
        grupo = gd["grupo"].upper() if gd.get("grupo") else None
        return {"letra": letra, "sujeto": suj, "grupo": grupo, "particion": None}

    # --- letra: la carpeta mas profunda que sea exactamente una letra; si no, un token del archivo
    letra, idx_letra = None, None
    for i in range(len(dirs) - 1, -1, -1):
        l = _letra_de_texto(dirs[i])
        if l:
            letra, idx_letra = l, i
            break
    if letra is None:
        for tok in re.split(r"[_\-\s.]+", _norm(stem)):
            if re.fullmatch(r"[a-zñ]|ll|rr|nn", tok):
                letra = _glosa_letra(tok)
                break

    # --- grupo: un componente ENCIMA de la carpeta de la letra (o cualquiera si no hay carpeta de letra)
    candidatos = dirs[:idx_letra] if idx_letra is not None else dirs
    grupo = None
    for p in candidatos:
        grupo = _grupo_de_texto(p)
        if grupo:
            break
    if grupo is None:
        grupo = _grupo_de_texto(stem)

    # --- particion
    particion = next((_norm(p) for p in dirs if _norm(p) in _PARTICION), None)

    # --- persona: del nombre del archivo; si no, de una carpeta
    suj = None
    for fuente in [stem] + list(reversed(dirs)):
        m = _SUJ_RX.search(_norm(fuente))
        if m:
            suj = int(m.group(1))
            break
    if suj is None:
        m = re.match(r"^(\d{1,3})[_\-\s]", _norm(stem))
        if m:
            suj = int(m.group(1))
    return {"letra": letra, "sujeto": suj, "grupo": grupo, "particion": particion}


def _clave_natural(nombre):
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", nombre)]


def indexar(carpeta, patron=None):
    """Recorre la carpeta. Devuelve (tomas, sin_entender) con tomas = {(grupo, sujeto, letra): [rutas
    ordenadas]}."""
    tomas, sin = {}, []
    for raiz, _d, archivos in os.walk(carpeta):
        if "__MACOSX" in raiz:
            continue
        for a in archivos:
            if a.startswith("._"):
                continue
            ruta = os.path.join(raiz, a)
            rel = os.path.relpath(ruta, carpeta).replace(os.sep, "/")
            info = analizar_ruta(rel, patron)
            if info is None:
                continue
            if info["letra"] is None or info["sujeto"] is None:
                sin.append((rel, info))
                continue
            clave = (info["grupo"] or "?", info["sujeto"], info["letra"])
            tomas.setdefault(clave, []).append(ruta)
    for lista in tomas.values():
        lista.sort(key=lambda r: _clave_natural(os.path.basename(r)))
    return tomas, sin


def nombre_toma(clave):
    grupo, suj, letra = clave
    if grupo == "?":                      # Windows no admite '?' en un nombre de archivo
        grupo = "X"
    return f"{grupo}_S{suj:02d}_{letra}.toma"


# ---------------------------------------------------------------------------
# 2. Imagen -> mano
# ---------------------------------------------------------------------------
def leer_imagen(ruta):
    import cv2
    import numpy as np
    datos = np.fromfile(ruta, dtype=np.uint8)          # imread falla con acentos en Windows
    img = cv2.imdecode(datos, cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError("imagen ilegible")
    return cv2.cvtColor(img, cv2.COLOR_BGR2RGB)


class DetectorManos:
    def __init__(self, modelo):
        import mediapipe as mp
        from mediapipe.tasks import python as mp_python
        from mediapipe.tasks.python import vision
        self.mp = mp
        self.det = vision.HandLandmarker.create_from_options(vision.HandLandmarkerOptions(
            base_options=mp_python.BaseOptions(model_asset_path=modelo),
            running_mode=vision.RunningMode.IMAGE, num_hands=2,
            min_hand_detection_confidence=0.5, min_hand_presence_confidence=0.5,
            min_tracking_confidence=0.5))

    def cerrar(self):
        self.det.close()

    def mano(self, rgb):
        """(21 puntos [x,y,z], etiqueta MediaPipe) de la mano mas cercana al centro del recorte, o
        (None, None)."""
        res = self.det.detect(self.mp.Image(image_format=self.mp.ImageFormat.SRGB, data=rgb))
        if not res.hand_landmarks:
            return None, None
        mejor, d_mejor = 0, 9.0
        for i, lm in enumerate(res.hand_landmarks):
            xs = [p.x for p in lm]
            ys = [p.y for p in lm]
            d = math.hypot((min(xs) + max(xs)) / 2 - 0.5, (min(ys) + max(ys)) / 2 - 0.5)
            if d < d_mejor:
                mejor, d_mejor = i, d
        pts = [[p.x, p.y, p.z] for p in res.hand_landmarks[mejor]]
        h = res.handedness[mejor] if mejor < len(res.handedness) else None
        return pts, (h[0].category_name if h else None)


def a_convencion_16_9(pts):
    return [[p[0] * K_16_9, p[1], p[2] * K_16_9] for p in pts]


# ---------------------------------------------------------------------------
# 3. Toma -> muestra
# ---------------------------------------------------------------------------
def ventana_quieta(vectores, largo):
    """vectores: lista de listas (forma de la mano, cuadros con mano, en orden). Devuelve (i0, i1, mov):
    la ventana de `largo` cuadros seguidos con menos cambio de forma (media de |delta| por cuadro)."""
    n = len(vectores)
    if n <= largo:
        return 0, n, None
    pasos = [sum(abs(a - b) for a, b in zip(vectores[i + 1], vectores[i])) / len(vectores[i])
             for i in range(n - 1)]
    mejor, mov_mejor = 0, float("inf")
    for i0 in range(0, n - largo + 1):
        mov = sum(pasos[i0:i0 + largo - 1]) / (largo - 1)
        if mov < mov_mejor:
            mejor, mov_mejor = i0, mov
    return mejor, mejor + largo, mov_mejor


def construir_toma(rutas, detector, args):
    """Devuelve el dict de la muestra (formato de importar_dataset_lsm.muestra_desde_raw mas campos
    propios). Lanza ValueError si no hay nada util."""
    n = len(rutas)
    ini, fin = 0, n
    if n >= 20:
        ini, fin = int(n * args.margen), int(math.ceil(n * (1.0 - args.margen)))
    elegidas = rutas[ini:fin:max(1, args.paso)]
    if not elegidas:
        raise ValueError("sin imagenes")

    dets = []                       # (indice dentro de elegidas, 21 pts, etiqueta)
    ilegibles = 0
    for i, r in enumerate(elegidas):
        try:
            pts, et = detector.mano(leer_imagen(r))
        except ValueError:
            ilegibles += 1
            continue
        if pts is not None:
            dets.append((i, pts, et))
    probadas = len(elegidas) - ilegibles
    if probadas == 0:
        raise ValueError("ninguna imagen legible")
    frac = len(dets) / probadas
    if not dets:
        return {"seq": None, "n_frames": len(elegidas), "n_frames_video": n, "fps": 30.0,
                "validos": 0, "frac_validos": 0.0, "frac_con_mano": 0.0, "frac_dos_manos": 0.0,
                "visibilidad_min": None, "votos_izq": 0, "votos_der": 0, "ventana": None,
                "movimiento": None, "recorte": [ini, fin], "cola_repetida": 0}

    izq = sum(1 for _i, _p, e in dets if e == "Left")
    der = sum(1 for _i, _p, e in dets if e == "Right")
    lado = "izq" if izq >= der else "der"                  # empate: izquierda (como un video sin espejo)

    manos = [a_convencion_16_9(p) if args.convencion_16_9 else p for _i, p, _e in dets]
    # forma de cada cuadro con mano, solo para buscar la ventana mas quieta
    formas = []
    for p in manos:
        f = sn.normalize_frame(POSE_NEUTRA, MUNDO_NEUTRO, p if lado == "izq" else None,
                               p if lado == "der" else None)
        formas.append(f[sn.OFF_SHAPE_L:sn.OFF_SHAPE_L + 60] if lado == "izq"
                      else f[sn.OFF_SHAPE_R:sn.OFF_SHAPE_R + 60])
    largo = max(6, int(round(args.ventana * 60.0 / max(1, args.paso))))   # cuadros tras el paso (60 fps)
    i0, i1, mov = ventana_quieta(formas, min(largo, len(formas)))
    raw = [(POSE_NEUTRA, MUNDO_NEUTRO, manos[k] if lado == "izq" else None,
            manos[k] if lado == "der" else None) for k in range(i0, i1)]
    m = imp.muestra_desde_raw(raw, 30.0, recortar=False)
    m.update({"n_frames_video": n, "frac_con_mano": frac, "frac_dos_manos": 0.0,
              "votos_izq": izq, "votos_der": der, "lado": lado,
              "ventana": [dets[i0][0], dets[i1 - 1][0]], "movimiento": mov,
              "recorte": [ini, fin], "imagenes_usadas": probadas, "imagenes_con_mano": len(dets)})
    # el esqueleto es inventado: "hombros visibles" no dice nada de la toma
    m["visibilidad_min"] = None
    return m


def veredicto_toma(m, args):
    if m.get("error"):
        return "ERROR: " + m["error"]
    if m["seq"] is None:
        return "ninguna imagen con mano detectada"
    if m["frac_con_mano"] < args.min_manos:
        return f"mano detectada solo en {m['frac_con_mano']:.0%} de las imagenes"
    if m["n_frames"] < 6:
        return f"muy pocas imagenes ({m['n_frames']})"
    return None


def procesar_tomas(tomas, args, carpeta_cache):
    """tomas: lista de (clave, rutas). Cache en un JSON por toma: si se corta, sigue donde se quedo."""
    os.makedirs(carpeta_cache, exist_ok=True)
    firma = {"imp": VERSION_IMPORTADOR, "norm": sn.NORM_VERSION, "paso": args.paso,
             "margen": args.margen, "ventana": args.ventana, "c169": bool(args.convencion_16_9)}
    pendientes, resultados = [], {}
    for clave, rutas in tomas:
        ruta_c = os.path.join(carpeta_cache, nombre_toma(clave) + ".json")
        ok = False
        if os.path.exists(ruta_c):
            try:
                with open(ruta_c, encoding="utf-8") as f:
                    c = json.load(f)
                if c.get("firma") == firma and c.get("n_imagenes") == len(rutas):
                    resultados[clave] = c["muestra"]
                    ok = True
            except Exception:
                ok = False
        if not ok:
            pendientes.append((clave, rutas, ruta_c))

    if pendientes:
        if not os.path.exists(args.hand_model):
            raise SystemExit(f"no encuentro el modelo de manos de MediaPipe: {args.hand_model}\n"
                             "Pasa --hand-model con la ruta de hand_landmarker.task.")
        detector = DetectorManos(args.hand_model)
        t0 = time.monotonic()
        try:
            for i, (clave, rutas, ruta_c) in enumerate(pendientes, 1):
                ini = time.monotonic()
                try:
                    m = construir_toma(rutas, detector, args)
                except Exception as e:
                    m = {"error": str(e), "seq": None, "n_frames": 0, "n_frames_video": len(rutas),
                         "fps": 30.0, "validos": 0, "frac_validos": 0.0, "frac_con_mano": 0.0,
                         "frac_dos_manos": 0.0, "visibilidad_min": None, "recorte": [0, 0],
                         "cola_repetida": 0}
                with open(ruta_c, "w", encoding="utf-8") as f:
                    json.dump({"firma": firma, "n_imagenes": len(rutas), "muestra": m}, f)
                resultados[clave] = m
                hecho = time.monotonic() - t0
                eta = hecho / i * (len(pendientes) - i)
                motivo = veredicto_toma(m, args)
                imp.log(f"  [{i:>4}/{len(pendientes)}] {nombre_toma(clave):<16} "
                        f"{len(rutas):>5} img  mano {m.get('frac_con_mano', 0):>4.0%}  "
                        f"({m.get('votos_izq', 0)}I/{m.get('votos_der', 0)}D)  "
                        f"{time.monotonic() - ini:4.1f}s  "
                        + (f"DESCARTADA: {motivo}" if motivo else "ok")
                        + f"   (faltan ~{imp.duracion(eta)})")
        finally:
            detector.cerrar()

    out = []
    for clave, rutas in tomas:
        grupo, suj, letra = clave
        m = dict(resultados[clave])
        m.update({"archivo": nombre_toma(clave), "gloss": letra, "nombre": letra, "sujeto": suj,
                  "grupo": grupo, "experto": False, "n_imagenes": len(rutas)})
        m["motivo"] = veredicto_toma(m, args)
        out.append(m)
    return out


# ---------------------------------------------------------------------------
# 4. Principal
# ---------------------------------------------------------------------------
def elegir_para_probar(tomas, n):
    """n tomas repartidas entre las letras: una por letra (letras espaciadas) y, si n pasa del numero de
    letras, la siguiente persona de cada una."""
    por_letra = {}
    for c in sorted(tomas, key=lambda c: (c[2], c[0], c[1])):
        por_letra.setdefault(c[2], []).append(c)
    letras = sorted(por_letra, key=lambda x: (len(x), x))
    elegidas = []
    for i in range(n):
        vuelta, k = divmod(i, len(letras))
        if len(letras) > n:
            k = int(k * len(letras) / n)
        lista = por_letra[letras[k]]
        elegidas.append(lista[min(vuelta, len(lista) - 1)])
    return list(dict.fromkeys(elegidas))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--carpeta", help="carpeta con las imagenes ya descomprimidas (si no, se baja)")
    ap.add_argument("--datos", default=imp.DATOS_DEFECTO,
                    help="donde guardar descarga, imagenes y cache")
    ap.add_argument("--grupo", default="A",
                    help="grupo de variacion: A (defecto, giros suaves), B, C, A,B o 'todos'")
    ap.add_argument("--sujetos", default="todos", help="'todos' o una lista: 1,2,3")
    ap.add_argument("--letras", default="", help="solo estas letras: A,B,C (defecto: todas las que haya)")
    ap.add_argument("--patron", help="expresion regular con (?P<letra>) (?P<sujeto>) [(?P<grupo>)] "
                                     "sobre la ruta relativa con '/' sin extension")
    ap.add_argument("--listar", action="store_true",
                    help="solo recorre la carpeta y dice que entendio; no usa MediaPipe ni la base")
    ap.add_argument("--probar", type=int, metavar="N",
                    help="procesa N tomas repartidas entre las letras, sin tocar la base")
    ap.add_argument("--paso", type=int, default=2,
                    help="usa 1 de cada N imagenes (los cuadros son a 60 fps; defecto 2)")
    ap.add_argument("--margen", type=float, default=0.15,
                    help="fraccion de imagenes que se descarta al inicio y al final de cada toma "
                         "(la mano entrando y saliendo); defecto 0.15")
    ap.add_argument("--ventana", type=float, default=0.5,
                    help="segundos de la ventana mas quieta que se toma de cada toma (defecto 0.5)")
    ap.add_argument("--min-manos", type=float, default=0.5,
                    help="se descarta la toma si el detector ve mano en menos de esta fraccion")
    ap.add_argument("--sin-convencion-16-9", dest="convencion_16_9", action="store_false",
                    help="guarda la forma tal cual sale del recorte cuadrado (ver arriba)")
    ap.add_argument("--deshacer", action="store_true",
                    help="deja 'rechazada' toda muestra de este dataset (no borra nada)")
    ap.add_argument("--rehacer", action="store_true",
                    help="--deshacer y vuelve a importar con las opciones de ahora")
    ap.add_argument("--seco", action="store_true", help="hace todo menos escribir en la base")
    ap.add_argument("--sin-base", action="store_true", help="solo prepara y reporta")
    ap.add_argument("--hand-model", default=os.path.join(imp.ASSETS, "hand_landmarker.task"))
    args = ap.parse_args()

    os.makedirs(args.datos, exist_ok=True)
    gi = os.path.join(args.datos, ".gitignore")
    if not os.path.exists(gi):
        with open(gi, "w") as f:
            f.write("*\n")
    imp._LOG = os.path.join(args.datos, "importacion.log")
    for flujo in (sys.stdout, sys.stderr):
        try:
            flujo.reconfigure(errors="replace")
        except Exception:
            pass
    # lo que lee importar_a_base de los argumentos de importar_dataset_lsm.py
    args.como_pendientes = True
    args.empalmes = "ambas"
    args.acuerdo = 0.5
    args.sin_exportar = True

    imp.log("=" * 70)
    imp.log(f"{CFG['titulo']}  [{CFG['licencia']}]")
    imp.log(f"{datetime.datetime.now():%Y-%m-%d %H:%M}   datos en: {args.datos}")
    imp.log("=" * 70)

    if args.deshacer:
        imp.log("\nDeshacer: las muestras de este dataset dejan de usarse" + ("  (--seco)" if args.seco else ""))
        imp.deshacer(CFG, args.datos, seco=args.seco)
        return

    patron = re.compile(args.patron) if args.patron else None
    if patron is not None and not {"letra", "sujeto"} <= set(patron.groupindex):
        raise SystemExit("--patron necesita los grupos (?P<letra>...) y (?P<sujeto>...)")

    # -- 1 y 2: bajar y descomprimir --------------------------------------------------------
    if args.carpeta:
        carpeta_img = args.carpeta
        imp.log(f"\n[1-2] usando las imagenes de {carpeta_img}")
    else:
        carpeta_dl = os.path.join(args.datos, f"{CFG['origen']}_{CFG['zenodo']}")
        carpeta_img = os.path.join(carpeta_dl, "imagenes")
        if os.path.exists(os.path.join(carpeta_img, ".extraido")):
            imp.log(f"\n[1-2] ya estaban descomprimidas en {carpeta_img}")
        else:
            libre = shutil.disk_usage(args.datos).free / 1024 ** 3
            if libre < ESPACIO_MIN_GB:
                raise SystemExit(f"hacen falta ~{ESPACIO_MIN_GB:.0f} GB libres (4.8 GB del archivo + las "
                                 f"imagenes descomprimidas) y en {args.datos} hay {libre:.1f} GB. "
                                 "Usa --datos con otra unidad.")
            imp.log("\n[1] Descarga (4.8 GB; reanuda si se corta)")
            archivo, _info = imp.descargar(CFG, carpeta_dl)
            imp.log("\n[2] Descompresion")
            imp.descomprimir(archivo, carpeta_img)

    # -- que hay -----------------------------------------------------------------------------
    tomas, sin = indexar(carpeta_img, patron)
    n_img = sum(len(v) for v in tomas.values())
    imp.log(f"\n{n_img} imagenes entendidas en {len(tomas)} tomas (grupo, persona, letra); "
            f"{len(sin)} imagenes sin letra o sin persona")
    por_grupo = {}
    for (g, s, l), v in tomas.items():
        por_grupo.setdefault(g, {"tomas": 0, "img": 0, "personas": set(), "letras": set()})
        d = por_grupo[g]
        d["tomas"] += 1
        d["img"] += len(v)
        d["personas"].add(s)
        d["letras"].add(l)
    for g in sorted(por_grupo):
        d = por_grupo[g]
        imp.log(f"  grupo {g}: {d['tomas']} tomas, {d['img']} imagenes, {len(d['personas'])} personas, "
                f"letras {''.join(sorted(d['letras'], key=lambda x: (len(x), x)))}")
    if sin:
        imp.log("  ejemplos de archivos que no pude entender (letra, persona):")
        for rel, info in sin[:8]:
            imp.log(f"    {rel}   -> letra={info['letra']} persona={info['sujeto']}")
        if not tomas:
            raise SystemExit("no entendi ninguna imagen. Mira esos nombres y pasa --patron (ver --help).")
        if len(sin) > 0.05 * (n_img + len(sin)):
            imp.log("  OJO: mas del 5 % de las imagenes quedaron sin clasificar; revisa --listar y --patron")

    if args.listar:
        ejemplos = sorted(tomas)[:12]
        imp.log("\nPrimeras tomas:")
        for c in ejemplos:
            imp.log(f"  {nombre_toma(c):<16} {len(tomas[c]):>5} imagenes   p. ej. "
                    f"{os.path.relpath(tomas[c][0], carpeta_img)}")
        imp.log("\n(--listar: termino aqui)")
        return

    # -- filtros -------------------------------------------------------------------------------
    if args.grupo.lower() != "todos":
        grupos = {g.strip().upper() for g in args.grupo.split(",") if g.strip()}
        if "?" in por_grupo and len(por_grupo) == 1:
            grupos = {"?"}                      # el dataset no dice el grupo: se usa todo
            imp.log("  (no pude saber el grupo de cada imagen; las uso todas)")
        tomas = {c: v for c, v in tomas.items() if c[0] in grupos}
    if args.sujetos.lower() != "todos":
        suj = {int(x) for x in args.sujetos.split(",") if x.strip()}
        tomas = {c: v for c, v in tomas.items() if c[1] in suj}
    if args.letras:
        let = {a_glosa(x) for x in args.letras.split(",") if x.strip()}
        tomas = {c: v for c, v in tomas.items() if c[2] in let}
    if not tomas:
        raise SystemExit(f"ninguna toma cumple los filtros (grupos que hay: {sorted(por_grupo)})")
    lista = sorted(tomas.items(), key=lambda kv: (kv[0][2], kv[0][0], kv[0][1]))
    if args.probar:
        elegidas = set(elegir_para_probar(tomas, args.probar))
        lista = [kv for kv in lista if kv[0] in elegidas]
        imp.log(f"modo prueba: {len(lista)} tomas repartidas entre las letras")
    letras = sorted({c[2] for c, _ in lista}, key=lambda x: (len(x), x))
    imp.log(f"\n{len(lista)} tomas a procesar, {len(letras)} letras: {' '.join(letras)}")

    # -- 3: manos -> muestras ------------------------------------------------------------------
    imp.log("\n[3] Mano en cada imagen, ventana mas quieta y normalizacion")
    cache = os.path.join(args.datos, f"{CFG['origen']}_{CFG['zenodo']}", "cache")
    muestras = procesar_tomas(lista, args, cache)
    buenas = [m for m in muestras if not m["motivo"]]
    malas = [m for m in muestras if m["motivo"]]

    ruta_csv = os.path.join(args.datos, "informe_alfabeto_estatico.csv")
    with open(ruta_csv, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["toma", "letra", "persona", "grupo", "imagenes", "con_mano", "votos_izq", "votos_der",
                    "lado", "movimiento_ventana", "descartada_por"])
        for m in muestras:
            w.writerow([m["archivo"], m["gloss"], m["sujeto"], m["grupo"], m["n_imagenes"],
                        f"{m['frac_con_mano']:.2f}", m.get("votos_izq", ""), m.get("votos_der", ""),
                        m.get("lado", ""),
                        "" if m.get("movimiento") is None else f"{m['movimiento']:.4f}",
                        m["motivo"] or ""])
    imp.log(f"\n{len(buenas)} tomas buenas, {len(malas)} descartadas  (detalle: {ruta_csv})")
    for m in malas[:12]:
        imp.log(f"  descartada {m['archivo']}: {m['motivo']}")
    if len(malas) > 12:
        imp.log(f"  ... y {len(malas) - 12} mas en el CSV")
    if buenas:
        izq = sum(1 for m in buenas if m.get("lado") == "izq")
        imp.log(f"  mano detectada en {statistics.mean(m['frac_con_mano'] for m in buenas):.0%} de las "
                f"imagenes (promedio); lado: {izq} tomas 'izquierda' de MediaPipe, "
                f"{len(buenas) - izq} 'derecha'")
        por_letra = {}
        for m in buenas:
            por_letra.setdefault(m["gloss"], set()).add(m["sujeto"])
        imp.log("  personas distintas por letra: "
                + "  ".join(f"{l}:{len(por_letra[l])}" for l in sorted(por_letra, key=lambda x: (len(x), x))))
        faltan = [l for l in letras if len(por_letra.get(l, ())) < 10]
        if faltan and not args.probar:
            imp.log("  OJO: menos de 10 personas distintas en: " + ", ".join(faltan))

    if args.probar:
        imp.log("\n--- RESULTADO DE LA PRUEBA ---")
        if len(buenas) < max(1, int(0.7 * len(muestras))):
            imp.log("REVISA antes de seguir: menos del 70 % de las tomas salio bien. Mira el CSV.")
            sys.exit(2)                       # para que un .bat no siga con la importacion completa
        else:
            imp.log("Las tomas salen bien. Siguiente paso:  python tools/importar_alfabeto_estatico.py"
                    + (f' --carpeta "{args.carpeta}"' if args.carpeta else ""))
        return

    # -- 5: base ---------------------------------------------------------------------------------
    if args.sin_base or not buenas:
        imp.log("\n(--sin-base: termino aqui)")
        return
    imp.log("\n[5] Base de datos" + ("  (--seco: no se escribe nada)" if args.seco else ""))
    if args.rehacer:
        imp.log("  deshaciendo la importacion anterior:")
        imp.deshacer(CFG, args.datos, seco=args.seco)
    r = imp.importar_a_base(buenas, CFG, args, args.datos)
    imp.log(f"  senas nuevas: {len(r['nuevas'])}   muestras {'a insertar' if args.seco else 'insertadas'}: "
            f"{r['muestras']}  (pendientes: {r['pendientes']}, ya estaban: {r['ya_estaban']})")
    ruta_cred = imp.escribir_creditos(args.datos, CFG)
    imp.log(f"  creditos (licencia {CFG['licencia']}): {ruta_cred}")
    imp.log("\nTodo quedo 'pendiente' y plantillas.json no cambio. Para aprobar hasta 10 personas por letra:")
    imp.log("    python tools/aprobar_dataset.py --dataset alfabeto_estatico --por-glosa 10 --seco")
    imp.log("    python tools/aprobar_dataset.py --dataset alfabeto_estatico --por-glosa 10")


if __name__ == "__main__":
    main()
