#!/usr/bin/env python3
"""Importa las 249 PALABRAS de la LSM de la UAEMex (cuadros de video de ~11 personas por palabra).

Dataset: "Mexican sign language dataset", Universidad Autonoma del Estado de Mexico, Mendeley Data
10.17632/6rj76z6y3n.1 (V1, 2023-10-02), CC BY 4.0 (licencia de la ficha del dataset; el articulo de
Data in Brief 55:110566 es CC BY-NC). 249 clases, 11 estudiantes Sordos, 31,442 JPG (~11 cuadros
por persona y palabra), pared y camisa negras, rostros difuminados, camara fija a 2.5 m, 1.76 GB
con "Download All". Una carpeta por clase (001-249), subcarpetas por persona, y un .xlsx con el
nombre de cada clase.

Estructura real (v2): MSLwords1/<palabra 001-249>/<PP+palabra>/<PPPPPFFF>.jpg  (p. ej. 001/01001/01001001.jpg:
persona 01, palabra 001, cuadro 001; ~13 cuadros por toma, 9-11 personas por palabra) y MSLwords1/classes.xlsx
con los nombres EN INGLES; clases_uaemex_es.csv (junto a este script) los pasa al espanol de la app.

Para que sirve: es la unica fuente publica que puede dar >= 10 grabaciones distintas a PALABRAS (no
letras) de salud, familia, tiempo, cuerpo, lugares, verbos, profesiones... (ver
claude/plan-cobertura-95-fuentes-lsm-2026-10-10.md).

Como lo hace (mismo camino que un video, tomando cada persona+palabra como una TOMA):
  - Los cuadros de una persona y palabra, en orden, se pasan por el mismo ExtractorLandmarks que
    los videos (pose + manos, RunningMode.VIDEO), con un fps SUPUESTO (--fps, defecto 10: el dataset
    no dice a que ritmo se sacaron los cuadros; solo cuenta para el reloj del seguimiento y para la
    duracion que se guarda; el reconocimiento remuestrea cada toma a 32 cuadros).
  - sign_norm 2.0.0 como siempre (cuerpo + ubicacion + forma de mano). Si el cuerpo no se detecta
    (ropa y fondo negros), --modo auto (defecto) reintenta en modo "solo mano": esqueleto neutro y
    ubicacion = desplazamiento de la muneca, igual que las letras dinamicas del CICESE.
  - No se recorta por movimiento (cada toma ya es solo la seña): --recortar lo activa.
  - Si en la carpeta hay VIDEOS de la persona y la palabra, se usan de preferencia (--solo-imagenes
    los ignora): con el ritmo real y la cola de quietud el recorte normal tiene sentido.

TODO entra a la base como 'pendiente' y plantillas.json no cambia. Para usarlo:
    python tools/aprobar_dataset.py --dataset uaemex --por-glosa 10 --existentes sumar --seco
    python tools/aprobar_dataset.py --dataset uaemex --por-glosa 10 --existentes sumar

Uso (desde senas_core):
    python tools/importar_uaemex.py --zip "D:\\Descargas\\Mexican sign language dataset.zip" --listar
    python tools/importar_uaemex.py --carpeta D:\\UAEMEX --listar      # solo mira como esta organizado
    python tools/importar_uaemex.py --carpeta D:\\UAEMEX --probar 10   # 10 tomas, sin tocar la base
    python tools/importar_uaemex.py --carpeta D:\\UAEMEX              # todo

Si la estructura real es distinta a la esperada: --listar dice que entendio y
    --patron "(?P<clase>\\d+)/(?P<persona>\\d+)/[^/]+"  (sobre la ruta relativa con '/', sin extension)
lo fuerza; y si el .xlsx no se lee, --clases RUTA.csv con lineas "numero,palabra".
"""

import argparse
import csv
import datetime
import gzip
import json
import math
import os
import re
import shutil
import statistics
import sys
import tempfile
import time
import unicodedata
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import importar_dataset_lsm as imp  # noqa: E402
import sign_norm as sn  # noqa: E402
from glosa import a_glosa  # noqa: E402

VERSION_IMPORTADOR = 3          # sube si cambia como se arma una toma (invalida el cache)
# v2: estructura real MSLwords1/<palabra>/<PP+palabra>/<img>, tomas "wCCC_pPP", nombres en espanol
# v3: se quitan los cuadros de REPOSO (brazos colgando) al inicio y al final de cada toma; la URI lleva
#     el sufijo ".r1" para no chocar con las muestras de la v2 (se dejan 'rechazada' con --limpiar-anteriores)

# Recorte de reposo. En las fotos de este dataset cada persona empieza y termina con los brazos
# colgando: con el recorte normal (que no se usa en fotos) ~70 % de los cuadros de cada toma eran reposo
# (comparar_uaemex_alturas.py, 11-oct-2026), contra ~20 % en lo ya aprobado. Aqui se quitan SOLO los
# cuadros de reposo del principio y del final. NO se cambia ninguna altura de muneca: lo que queda es
# tal cual lo midio MediaPipe (regla del proyecto: no normalizar ni mover alturas).
REPOSO_Y = -0.9                 # muneca mas abajo de esto (anchos de hombro) = brazo colgando
MARGEN_REPOSO = 1               # cuadros de reposo que se dejan antes y despues de la sena
MIN_FRAMES_REPOSO = 4           # si despues de recortar quedan menos, la toma se queda sin recortar
SUFIJO_REPOSO = ".r1"

CFG = {
    "titulo": "Mexican sign language dataset (UAEMex, 249 palabras)",
    "zenodo": "6rj76z6y3n",                 # aqui guarda el id de Mendeley (video_uri 'mendeley:6rj76z6y3n/...')
    "origen": "mendeley",
    "expertos": set(),
    "solo_pendientes": True,
    "categoria": "general",
    "licencia": "CC BY 4.0",
    "cita": ("Espejel, J., Dominguez, L. Y., Cervantes, J., & Cervantes, J. (2023). Mexican sign "
             "language dataset [Data set]. Universidad Autonoma del Estado de Mexico. Mendeley Data, V1. "
             "https://doi.org/10.17632/6rj76z6y3n.1 (autores segun la ficha de Mendeley)"),
    "credito": "(UAEMex, CC BY 4.0), https://doi.org/10.17632/6rj76z6y3n.1",
}

EXT_IMAGEN = (".jpg", ".jpeg", ".png", ".bmp")
EXT_VIDEO = (".mp4", ".mov", ".avi", ".mkv", ".m4v")
FPS_ASUMIDO = 10.0
ESPACIO_MIN_GB = 6.0            # 1.76 GB del zip + descomprimido + margen
_NUM_RX = re.compile(r"^(?:[a-z]+[_\- ]*)?0*(\d{1,3})(?:[_\- .]+[^\d].*)?$")   # "001", "Clase 1", "P03", "12 - Abrir", "001_Abrir"
_PERSONA_RX = re.compile(r"^(?:persona|person|p|sujeto|subject|s|individuo|ind|estudiante|student|signer|usuario|user)[_\- ]*\d")


# ---------------------------------------------------------------------------
# 1. Que hay en la carpeta
# ---------------------------------------------------------------------------
def _norm(t):
    return unicodedata.normalize("NFC", t).strip().lower()


def _clave_natural(nombre):
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", nombre)]


def analizar_ruta(rel, patron=None):
    """rel: ruta relativa con '/'. Devuelve (tipo, clase, persona) con None donde no se pudo,
    o None si no es imagen ni video."""
    base, ext = os.path.splitext(rel)
    ext = ext.lower()
    tipo = "imagen" if ext in EXT_IMAGEN else "video" if ext in EXT_VIDEO else None
    if tipo is None:
        return None
    if patron is not None:
        m = patron.search(base)
        if not m:
            return tipo, None, None
        gd = m.groupdict()
        cl = int(gd["clase"]) if gd.get("clase") and gd["clase"].isdigit() else None
        pe = int(gd["persona"]) if gd.get("persona") and gd["persona"].isdigit() else None
        return tipo, cl, pe
    partes = [unicodedata.normalize("NFC", p) for p in base.split("/")]
    dirs = partes[:-1]
    # Estructura REAL de UAEMex: .../MSLwords1/<palabra 001-249>/<PP+palabra, 5 digitos>/<PPPPPFFF>.jpg
    # (p. ej. 001/01001/01001001.jpg). La palabra es la carpeta de 3 digitos; la persona son los DOS
    # primeros digitos de la carpeta de 5. Se confia en la carpeta de la palabra y no en los ultimos 3
    # digitos de la de 5 (en 249/ hay una carpeta "08248" cuyas fotos son 08249xxx: error del dataset).
    if len(dirs) >= 2 and re.fullmatch(r"\d{3}", dirs[-2]) and re.fullmatch(r"\d{5}", dirs[-1]):
        return tipo, int(dirs[-2]), int(dirs[-1][:2])
    nums, es_persona = [], []
    for d in dirs:
        m = _NUM_RX.match(_norm(d))
        if m:
            nums.append(int(m.group(1)))
            es_persona.append(bool(_PERSONA_RX.match(_norm(d))))
    if len(nums) >= 2:
        return tipo, nums[-2], nums[-1]            # .../<clase>/<persona>/archivo
    if len(nums) == 1 and es_persona[0]:           # .../<palabra>/Persona 3/archivo: la clase va por nombre
        return tipo, None, nums[0]                 # (no la invento; que el usuario use --patron)
    if len(nums) == 1:                             # .../<clase>/<algo con la persona en el nombre>
        m = re.search(r"(?:^|[_\-\s.])(?:p|persona|person|s|sujeto|subject|ind)?[_\-]?(\d{1,3})(?:[_\-\s.]|$)",
                      _norm(partes[-1]))
        return tipo, nums[0], int(m.group(1)) if m else None
    return tipo, None, None


def _inferir_por_numeros(items):
    """Ultimo recurso cuando los nombres no siguen carpeta/clase/persona: mira los NUMEROS de toda
    la ruta (carpetas + nombre). Si casi todos los archivos tienen los mismos 3 numeros, el que mas
    valores distintos toma (<= 400) es la clase, el ultimo es el numero de cuadro y el que queda es
    la persona. items: [(ruta, rel, tipo)]. Devuelve ({ruta: (clase, persona)}, descripcion) o ({}, None)."""
    toks = {}
    for ruta, rel, tipo in items:
        base = os.path.splitext(unicodedata.normalize("NFC", rel))[0]
        toks[ruta] = [int(x) for x in re.findall(r"\d+", base)]
    frecuentes = {}
    for t in toks.values():
        frecuentes[len(t)] = frecuentes.get(len(t), 0) + 1
    if not frecuentes:
        return {}, None
    k = max(frecuentes, key=frecuentes.get)
    if k != 3 or frecuentes[k] < 0.8 * len(items):
        return {}, None
    validos = [t for t in toks.values() if len(t) == k]
    distintos = [len({t[i] for t in validos}) for i in range(k)]
    pos_clase = max(range(k), key=lambda i: distintos[i])
    if distintos[pos_clase] > 400 or pos_clase == k - 1:
        return {}, None
    pos_cuadro = k - 1
    pos_persona = [i for i in range(k) if i not in (pos_clase, pos_cuadro)][0]
    if distintos[pos_clase] < 2 * max(distintos[pos_persona], 1) and distintos[pos_clase] > 12:
        return {}, None                                  # no se distingue la clase de la persona
    out = {r: (t[pos_clase], t[pos_persona]) for r, t in toks.items() if len(t) == k}
    desc = (f"deduje por los numeros de la ruta: clase=#{pos_clase + 1} ({distintos[pos_clase]} valores), "
            f"persona=#{pos_persona + 1} ({distintos[pos_persona]}), cuadro=#{pos_cuadro + 1} "
            f"({distintos[pos_cuadro]})")
    return out, desc


def indexar(carpeta, patron=None, solo_imagenes=False):
    """Devuelve (tomas, sin_entender): tomas = {(clase, persona): {'imagenes': [...], 'videos': [...]}}."""
    tomas, sin, todos = {}, [], []
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
            tipo, clase, persona = info
            if solo_imagenes and tipo == "video":
                continue
            todos.append((ruta, rel, tipo, clase, persona))
    ok = sum(1 for t in todos if t[3] is not None and t[4] is not None)
    inferido = {}
    if patron is None and todos and ok < 0.5 * len(todos):
        inferido, desc = _inferir_por_numeros([(r, rel, tp) for r, rel, tp, _c, _p in todos])
        if inferido:
            imp.log(f"  (los nombres no siguen carpeta/clase/persona; {desc}. Revisalo abajo; "
                    "si no es lo correcto, usa --patron)")
    for ruta, rel, tipo, clase, persona in todos:
        if (clase is None or persona is None) and ruta in inferido:
            clase, persona = inferido[ruta]
        if clase is None or persona is None:
            sin.append((rel, clase, persona))
            continue
        t = tomas.setdefault((clase, persona), {"imagenes": [], "videos": []})
        t["imagenes" if tipo == "imagen" else "videos"].append(ruta)
    for t in tomas.values():
        t["imagenes"].sort(key=lambda r: _clave_natural(os.path.basename(r)))
        t["videos"].sort(key=lambda r: _clave_natural(os.path.basename(r)))
    return tomas, sin


def nombre_toma(clave):
    # v2: prefijo "w" (palabra). La v1 usaba "001_P05.toma" mal armado (todas las palabras como la 1); con
    # otro nombre la URI en la base es distinta y no choca con esas muestras (se limpian con --limpiar-v1).
    clase, persona = clave
    return f"w{clase:03d}_p{persona:02d}.toma"


# ---------------------------------------------------------------------------
# 2. Numero de clase -> palabra (el .xlsx del dataset)
# ---------------------------------------------------------------------------
def _entero(x):
    if isinstance(x, bool):
        return None
    if isinstance(x, int):
        return x
    if isinstance(x, float) and x == int(x):
        return int(x)
    if isinstance(x, str) and re.fullmatch(r"\s*0*\d{1,3}\s*", x):
        return int(x)
    return None


def _texto_palabra(x):
    if not isinstance(x, str):
        return None
    t = unicodedata.normalize("NFC", x).strip()
    if not t or len(t) > 60 or not re.search(r"[A-Za-zÁÉÍÓÚÜÑáéíóúüñ]", t):
        return None
    return t


def mapa_desde_filas(filas):
    """filas: lista de listas de celdas. Elige la columna de numeros de clase (la que mas enteros
    distintos 1..300 tiene) y la columna de palabras (la que mas textos distintos tiene, a la derecha
    o izquierda del numero). Devuelve {numero: palabra}."""
    if not filas:
        return {}
    ncol = max(len(f) for f in filas)
    mejor_num, n_num = None, 0
    for c in range(ncol):
        vals = {_entero(f[c]) for f in filas if c < len(f)}
        vals = {v for v in vals if v is not None and 1 <= v <= 300}
        if len(vals) > n_num:
            mejor_num, n_num = c, len(vals)
    if mejor_num is None or n_num < 10:
        return {}
    cand = []
    for c in range(ncol):
        if c == mejor_num:
            continue
        vals = {_texto_palabra(f[c]) for f in filas if c < len(f)}
        vals.discard(None)
        cand.append((len(vals), -abs(c - mejor_num), c))
    if not cand:
        return {}
    cand.sort(reverse=True)
    col_pal = cand[0][2]
    out = {}
    for f in filas:
        if mejor_num < len(f) and col_pal < len(f):
            n, p = _entero(f[mejor_num]), _texto_palabra(f[col_pal])
            if n is not None and p and n not in out:
                out[n] = p
    return out


def leer_clases(carpeta, ruta=None):
    """Busca el .xlsx/.xls/.csv con las clases (o usa `ruta`). Devuelve ({numero: palabra}, de_donde)."""
    candidatos = []
    if ruta:
        candidatos = [ruta]
    else:
        for raiz, _d, archivos in os.walk(carpeta):
            for a in sorted(archivos):
                if a.lower().endswith((".xlsx", ".xlsm", ".csv", ".tsv")) and not a.startswith(("~", "._")):
                    candidatos.append(os.path.join(raiz, a))
    for c in candidatos:
        try:
            filas = []
            if c.lower().endswith((".xlsx", ".xlsm")):
                import openpyxl
                wb = openpyxl.load_workbook(c, read_only=True, data_only=True)
                for ws in wb.worksheets:
                    f = [list(r) for r in ws.iter_rows(values_only=True)]
                    m = mapa_desde_filas(f)
                    if m:
                        return m, f"{c} (hoja {ws.title})"
                continue
            with open(c, encoding="utf-8-sig", newline="") as fh:
                texto = fh.read()
            delim = ";" if texto.count(";") > texto.count(",") else ("\t" if "\t" in texto[:2000] else ",")
            filas = [row for row in csv.reader(texto.splitlines(), delimiter=delim)]
            m = mapa_desde_filas(filas)
            if m:
                return m, c
        except Exception as e:                      # un archivo ilegible no detiene a los demas
            imp.log(f"  (no pude leer {c}: {e})")
    return {}, None


NOMBRES_ES_DEFECTO = os.path.join(HERE, "clases_uaemex_es.csv")


def leer_nombres_es(ruta):
    """clases_uaemex_es.csv (numero,ingles,espanol,nota) -> {numero: palabra en espanol}.
    El .xlsx del dataset esta en INGLES ("Good morning") y la app usa glosas en espanol (BUENOS_DIAS):
    sin esta traduccion cada palabra entraria como una sena nueva con nombre en ingles."""
    if not ruta or not os.path.exists(ruta):
        return {}
    out = {}
    with open(ruta, encoding="utf-8-sig", newline="") as fh:
        for fila in csv.DictReader(fh):
            n = _entero((fila.get("numero") or "").strip())
            pal = _texto_palabra(fila.get("espanol") or "")
            if n is not None and pal:
                out[n] = pal
    return out


def limpiar_v1(seco=False):
    """La primera version del importador entendio mal las carpetas: metio las 249 palabras como UNA
    ("Good morning") y cada toma mezclaba a las personas. Esas muestras se reconocen porque su nombre
    de toma NO empieza con "w" (001_P05.toma). Se dejan 'rechazada' (no se borra nada). Se puede
    correr las veces que sea: la segunda vez ya no encuentra nada."""
    from dotenv import load_dotenv
    load_dotenv()
    import db
    prefijo = f"{CFG['origen']}:{CFG['zenodo']}/"
    conn = db.conectar()
    try:
        cur = conn.cursor()
        cur.execute("SELECT count(*) FROM sign_samples WHERE video_uri LIKE %s AND video_uri NOT LIKE %s "
                    "AND estado <> 'rechazada'", (prefijo + "%", prefijo + "w%"))
        n = cur.fetchone()[0]
        imp.log(f"  muestras de la importacion equivocada (v1) todavia en uso: {n}")
        if seco:
            conn.rollback()
            return n
        if n:
            cur.execute("UPDATE sign_samples SET estado = 'rechazada' WHERE video_uri LIKE %s "
                        "AND video_uri NOT LIKE %s AND estado <> 'rechazada'", (prefijo + "%", prefijo + "w%"))
            imp.log(f"  -> {cur.rowcount} muestras dejadas como 'rechazada' (siguen en la base, solo no se usan)")
        conn.commit()
        return n
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def limpiar_anteriores(seco=False):
    """Deja 'rechazada' las muestras de la v2 (toma "w001_p01.toma", sin el sufijo ".r1" del recorte de
    reposo). No borra nada y se puede correr las veces que sea. Con --seco solo cuenta."""
    from dotenv import load_dotenv
    load_dotenv()
    import db
    prefijo = f"{CFG['origen']}:{CFG['zenodo']}/"
    conn = db.conectar()
    try:
        cur = conn.cursor()
        sql_where = ("video_uri LIKE %s AND video_uri NOT LIKE %s AND video_uri NOT LIKE %s "
                     "AND estado <> 'rechazada'")
        par = (prefijo + "w%", "%" + SUFIJO_REPOSO + "#%", "%" + SUFIJO_REPOSO)
        cur.execute("SELECT count(*), count(*) FILTER (WHERE estado = 'aprobada') FROM sign_samples WHERE " + sql_where, par)
        n, n_apr = cur.fetchone()
        imp.log(f"  muestras de la v2 (sin recorte de reposo) todavia en uso: {n}  (aprobadas: {n_apr})")
        if seco:
            conn.rollback()
            return n
        if n_apr:
            raise SystemExit("hay muestras APROBADAS de la v2: no las toco. Revisa con tu mano antes de seguir.")
        if n:
            cur.execute("UPDATE sign_samples SET estado = 'rechazada' WHERE " + sql_where, par)
            imp.log(f"  -> {cur.rowcount} muestras dejadas como 'rechazada' (siguen en la base, solo no se usan)")
        conn.commit()
        return n
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# 3. Cuadros -> landmarks
# ---------------------------------------------------------------------------
def leer_imagen(ruta):
    import cv2
    import numpy as np
    datos = np.fromfile(ruta, dtype=np.uint8)          # imread falla con acentos en Windows
    img = cv2.imdecode(datos, cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError("imagen ilegible")
    return cv2.cvtColor(img, cv2.COLOR_BGR2RGB)


def crear_extractor(pose_model, hand_model):
    """ExtractorLandmarks (el de los videos) con un metodo para una lista de imagenes."""
    import extraer_landmarks as el
    import mediapipe as mp

    class ExtractorImagenes(el.ExtractorLandmarks):
        def extraer_imagenes(self, rutas, fps):
            """Igual que extraer() pero sobre imagenes en orden. Devuelve (raw, fps, n, aspecto)."""
            t_base = self._proximo_t_ms
            raw, idx, t_ms, aspecto = [], 0, t_base, None
            for ruta in rutas:
                try:
                    rgb = leer_imagen(ruta)
                except ValueError:
                    continue
                if aspecto is None:
                    aspecto = rgb.shape[1] / rgb.shape[0]
                t_ms = t_base + int(idx * 1000 / fps)
                mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
                pose_res = self.pose.detect_for_video(mp_image, t_ms)
                hand_res = self.hands.detect_for_video(mp_image, t_ms)
                pose = pose_mundo = None
                if pose_res.pose_landmarks:
                    pose = [el._punto_pose(p) for p in pose_res.pose_landmarks[0]]
                if getattr(pose_res, "pose_world_landmarks", None):
                    pose_mundo = [el._punto_mundo(p) for p in pose_res.pose_world_landmarks[0]]
                left = right = None
                for lm, handed in zip(hand_res.hand_landmarks, hand_res.handedness):
                    etiqueta = handed[0].category_name if handed else None
                    pts = [el._punto_mano(p) for p in lm]
                    if etiqueta == "Left":
                        left = pts
                    else:
                        right = pts
                raw.append((pose, pose_mundo, left, right))
                idx += 1
            self._proximo_t_ms = t_ms + 1000
            return raw, fps, idx, aspecto or 1.0

    return ExtractorImagenes(pose_model, hand_model)


def _ruta_raw(ruta_cache):
    return ruta_cache[:-len(".json")] + ".raw.json.gz"


def _guardar_raw(ruta_cache, raw, fps, n, aspecto):
    with gzip.open(_ruta_raw(ruta_cache), "wt", encoding="utf-8") as f:
        json.dump({"fps": fps, "n": n, "aspecto": aspecto, "raw": imp._redondear_raw(raw)}, f)


def _cargar_raw(ruta_cache):
    try:
        with gzip.open(_ruta_raw(ruta_cache), "rt", encoding="utf-8") as f:
            c = json.load(f)
        return [tuple(fr) for fr in c["raw"]], c["fps"], c["n"], c.get("aspecto", 1.0)
    except Exception:
        return None


def altura_mano_alta(cuadro):
    """Altura (anchos de hombro, arriba +) de la muneca MAS ALTA con mano detectada en este cuadro, o None
    si no hay cuerpo normalizable o no hay mano."""
    p, pm, l, r = cuadro
    v = sn.normalize_frame(p, pm, l, r)
    if v is None:
        return None
    ys = [v[off_loc + 1] for off_pres, off_loc in ((sn.OFF_PRES_L, sn.OFF_LOC_L), (sn.OFF_PRES_R, sn.OFF_LOC_R))
          if v[off_pres] >= 0.5]
    return max(ys) if ys else None


def recortar_reposo(raw, reposo_y=REPOSO_Y, margen=MARGEN_REPOSO, minimo=MIN_FRAMES_REPOSO):
    """Quita los cuadros de reposo (muneca por debajo de reposo_y) del principio y del final.
    Devuelve (raw_recortado, (ini, fin) o None si no se recorto)."""
    alturas = [altura_mano_alta(c) for c in raw]
    activos = [i for i, h in enumerate(alturas) if h is not None and h > reposo_y]
    if not activos:
        return raw, None                    # nunca sale del reposo (o sin cuerpo): se deja igual
    ini = max(0, activos[0] - margen)
    fin = min(len(raw) - 1, activos[-1] + margen)
    if fin - ini + 1 < minimo or (ini == 0 and fin == len(raw) - 1):
        return raw, None
    return raw[ini:fin + 1], (ini, fin)


def muestra_de_toma(raw, fps, aspecto, args):
    """raw -> dict de muestra. modo 'auto': con cuerpo y, si no sirve, solo mano."""
    m, modo = None, "cuerpo"
    if args.modo in ("auto", "cuerpo"):
        raw_c, rec = (recortar_reposo(raw) if args.recorte_reposo else (raw, None))
        m = imp.muestra_desde_raw(raw_c, fps, recortar=args.recortar and rec is None)
        m["recorte_reposo"] = list(rec) if rec else None
    if args.modo == "mano" or (args.modo == "auto" and imp.veredicto(m) is not None):
        m2 = imp.muestra_desde_raw(raw, fps, recortar=args.recortar, solo_mano=True, aspecto=aspecto)
        if args.modo == "mano" or (m2["seq"] is not None and imp.veredicto(m2) is None):
            m, modo = m2, "mano"
    m["modo_cuerpo"] = modo
    return m


def veredicto_toma(m):
    if m.get("error"):
        return "ERROR: " + m["error"]
    return imp.veredicto(m)


def procesar_tomas(lista, mapa, args, carpeta_cache):
    """lista: [((clase, persona), {'imagenes': [...], 'videos': [...]})]. Un JSON por toma (y los
    landmarks crudos comprimidos): si se corta sigue donde se quedo, y si cambia el modo o el recorte
    se recalcula sin volver a correr MediaPipe."""
    os.makedirs(carpeta_cache, exist_ok=True)
    firma = {"imp": VERSION_IMPORTADOR, "norm": sn.NORM_VERSION, "fps": args.fps, "modo": args.modo,
             "recortar": bool(args.recortar), "solo_imagenes": bool(args.solo_imagenes),
             "trim": imp.TRIM_VERSION, "solo_mano": imp.SOLO_MANO_VERSION,
             "reposo": [bool(args.recorte_reposo), REPOSO_Y, MARGEN_REPOSO, MIN_FRAMES_REPOSO]}
    pendientes, resultados = [], {}
    for clave, t in lista:
        ruta_c = os.path.join(carpeta_cache, nombre_toma(clave) + ".json")
        n_arch = len(t["videos"][:1]) if (t["videos"] and not args.solo_imagenes) else len(t["imagenes"])
        ok = False
        if os.path.exists(ruta_c):
            try:
                with open(ruta_c, encoding="utf-8") as f:
                    c = json.load(f)
                if c.get("firma") == firma and c.get("n_archivos") == n_arch:
                    resultados[clave] = c["muestra"]
                    ok = True
            except Exception:
                ok = False
        if not ok:
            pendientes.append((clave, t, ruta_c, n_arch))

    if pendientes:
        for p in (args.pose_model, args.hand_model):
            if not os.path.exists(p):
                raise SystemExit(f"no encuentro el modelo de MediaPipe: {p}\n"
                                 "Pasa --pose-model / --hand-model con la ruta correcta.")
        extractor = crear_extractor(args.pose_model, args.hand_model)
        tmp = tempfile.mkdtemp(prefix="lsm_")
        t0 = time.monotonic()
        try:
            for i, (clave, t, ruta_c, n_arch) in enumerate(pendientes, 1):
                ini = time.monotonic()
                fuente = "video" if (t["videos"] and not args.solo_imagenes) else "imagenes"
                try:
                    cargado = _cargar_raw(ruta_c)
                    if cargado is None:
                        if fuente == "video":
                            ext = os.path.splitext(t["videos"][0])[1].lower()
                            copia = os.path.join(tmp, "v" + ext)        # OpenCV en Windows no abre acentos
                            shutil.copyfile(t["videos"][0], copia)
                            raw, fps, n = extractor.extraer(copia)
                            aspecto = 1.0
                            if n == 0:
                                raise ValueError("video sin cuadros legibles")
                        else:
                            raw, fps, n, aspecto = extractor.extraer_imagenes(t["imagenes"], args.fps)
                            if n == 0:
                                raise ValueError("ninguna imagen legible")
                        _guardar_raw(ruta_c, raw, fps, n, aspecto)
                    else:
                        raw, fps, n, aspecto = cargado
                    m = muestra_de_toma(raw, fps, aspecto, args)
                    # un video real se recorta por movimiento como cualquier otro; las imagenes no
                    m.update({"fuente": fuente, "fps_supuesto": fuente == "imagenes"})
                except SystemExit:
                    raise
                except Exception as e:
                    m = {"error": str(e), "seq": None, "n_frames": 0, "n_frames_video": 0, "fps": 0,
                         "validos": 0, "frac_validos": 0.0, "frac_con_mano": 0.0, "frac_dos_manos": 0.0,
                         "visibilidad_min": None, "recorte": [0, 0], "cola_repetida": 0,
                         "fuente": fuente, "modo_cuerpo": "-"}
                with open(ruta_c, "w", encoding="utf-8") as f:
                    json.dump({"firma": firma, "n_archivos": n_arch, "muestra": m}, f)
                resultados[clave] = m
                hecho = time.monotonic() - t0
                eta = hecho / i * (len(pendientes) - i)
                motivo = veredicto_toma(m)
                clase, persona = clave
                imp.log(f"  [{i:>4}/{len(pendientes)}] {nombre_toma(clave):<14} "
                        f"{(mapa.get(clase) or '?')[:16]:<16} {m.get('n_frames_video', 0):>3} cuadros  "
                        f"{m.get('modo_cuerpo', '-'):<6} validos {m.get('frac_validos', 0):>4.0%}  "
                        f"manos {m.get('frac_con_mano', 0):>4.0%}  {time.monotonic() - ini:4.1f}s  "
                        + (f"DESCARTADA: {motivo}" if motivo else "ok")
                        + f"   (faltan ~{imp.duracion(eta)})")
        finally:
            extractor.cerrar()
            shutil.rmtree(tmp, ignore_errors=True)

    out = []
    for clave, _t in lista:
        clase, persona = clave
        m = dict(resultados[clave])
        palabra = mapa.get(clase) or f"clase {clase}"
        m.update({"archivo": nombre_toma(clave) + (SUFIJO_REPOSO if args.recorte_reposo else ""), "gloss": a_glosa(palabra), "nombre": palabra,
                  "sujeto": persona, "clase": clase, "experto": False})
        m["motivo"] = veredicto_toma(m)
        out.append(m)
    return out


# ---------------------------------------------------------------------------
# 4. Principal
# ---------------------------------------------------------------------------
def elegir_para_probar(claves, n):
    """n tomas repartidas entre clases distintas (una por clase, espaciadas) y personas distintas."""
    por_clase = {}
    for c in sorted(claves):
        por_clase.setdefault(c[0], []).append(c)
    clases = sorted(por_clase)
    elegidas = []
    for i in range(n):
        vuelta, k = divmod(i, len(clases))
        if len(clases) > n:
            k = int(k * len(clases) / n)
        lista = por_clase[clases[k]]
        elegidas.append(lista[min(vuelta + i, len(lista) - 1)])
    return list(dict.fromkeys(elegidas))


def extraer_zip(ruta_zip, destino):
    """Descomprime el zip de 'Download All' (y los .zip que traiga adentro, un nivel)."""
    os.makedirs(destino, exist_ok=True)
    imp.log(f"  descomprimiendo {ruta_zip} -> {destino}")
    with zipfile.ZipFile(ruta_zip) as z:
        z.extractall(destino)
    for raiz, _d, archivos in os.walk(destino):
        for a in archivos:
            if a.lower().endswith(".zip"):
                p = os.path.join(raiz, a)
                imp.log(f"  zip dentro del zip: {a}")
                with zipfile.ZipFile(p) as z:
                    z.extractall(os.path.join(raiz, os.path.splitext(a)[0]))
    with open(os.path.join(destino, ".extraido"), "w") as f:
        f.write("ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--carpeta", help="carpeta con el dataset ya descomprimido")
    ap.add_argument("--zip", help="zip de 'Download All' de Mendeley (se descomprime en --datos)")
    ap.add_argument("--datos", default=imp.DATOS_DEFECTO, help="donde guardar descomprimido y cache")
    ap.add_argument("--clases", help=".xlsx/.csv con 'numero,palabra' si el del dataset no se lee")
    ap.add_argument("--nombres-es", default=NOMBRES_ES_DEFECTO,
                    help="csv numero,ingles,espanol,nota con el nombre en ESPANOL de cada clase "
                         "(defecto: clases_uaemex_es.csv junto a este script; si no existe se usa el ingles)")
    ap.add_argument("--limpiar-v1", action="store_true",
                    help="deja 'rechazada' la importacion equivocada de la v1 (nombres 001_P05.toma); "
                         "con --seco solo cuenta")
    ap.add_argument("--limpiar-anteriores", action="store_true",
                    help="deja 'rechazada' las muestras de la v2 (sin sufijo .r1, antes del recorte de reposo); "
                         "con --seco solo cuenta")
    ap.add_argument("--sin-recorte-reposo", action="store_true",
                    help="NO quita los cuadros de reposo (brazos colgando) al inicio y al final de cada toma")
    ap.add_argument("--patron", help="regex con (?P<clase>\\d+) y (?P<persona>\\d+) sobre la ruta relativa "
                                     "con '/' sin extension")
    ap.add_argument("--listar", action="store_true",
                    help="solo recorre la carpeta y dice que entendio; no usa MediaPipe ni la base")
    ap.add_argument("--probar", type=int, metavar="N",
                    help="procesa N tomas repartidas entre clases, sin tocar la base")
    ap.add_argument("--fps", type=float, default=FPS_ASUMIDO,
                    help=f"ritmo SUPUESTO de los cuadros (defecto {FPS_ASUMIDO:g}); el dataset no lo dice")
    ap.add_argument("--modo", choices=["auto", "cuerpo", "mano"], default="auto",
                    help="auto (defecto): cuerpo y, si no se ven los hombros, solo mano")
    ap.add_argument("--recortar", action="store_true", help="recorta por movimiento como en un video")
    ap.add_argument("--solo-imagenes", action="store_true", help="ignora los videos si los hay")
    ap.add_argument("--palabras", default="", help="solo estas palabras (glosas o textos): hola,adios")
    ap.add_argument("--personas", default="todos", help="'todos' o una lista: 1,2,3")
    ap.add_argument("--deshacer", action="store_true",
                    help="deja 'rechazada' toda muestra de este dataset (no borra nada)")
    ap.add_argument("--rehacer", action="store_true", help="--deshacer y vuelve a importar")
    ap.add_argument("--seco", action="store_true", help="hace todo menos escribir en la base")
    ap.add_argument("--sin-base", action="store_true", help="solo prepara y reporta")
    ap.add_argument("--pose-model", default=os.path.join(imp.ASSETS, "pose_landmarker_lite.task"))
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
    args.sin_recorte = not args.recortar
    args.recorte_reposo = not args.sin_recorte_reposo
    if args.recorte_reposo:
        imp.MIN_FRAMES = MIN_FRAMES_REPOSO    # toma de fotos: pocos cuadros de sena; veredicto() lo usa

    imp.log("=" * 70)
    imp.log(f"{CFG['titulo']}  [{CFG['licencia']}]")
    imp.log(f"{datetime.datetime.now():%Y-%m-%d %H:%M}   datos en: {args.datos}")
    imp.log("=" * 70)

    if args.limpiar_v1:
        imp.log("\nLimpiar la importacion equivocada (v1)" + ("  (--seco)" if args.seco else ""))
        limpiar_v1(seco=args.seco)
        return

    if args.limpiar_anteriores:
        imp.log("\nLimpiar las muestras de la v2 (sin recorte de reposo)" + ("  (--seco)" if args.seco else ""))
        limpiar_anteriores(seco=args.seco)
        return

    if args.deshacer:
        imp.log("\nDeshacer: las muestras de este dataset dejan de usarse" + ("  (--seco)" if args.seco else ""))
        imp.deshacer(CFG, args.datos, seco=args.seco)
        return

    patron = re.compile(args.patron) if args.patron else None
    if patron is not None and not {"clase", "persona"} <= set(patron.groupindex):
        raise SystemExit("--patron necesita los grupos (?P<clase>...) y (?P<persona>...)")

    # -- 1: de donde salen las imagenes ----------------------------------------------------------
    if args.carpeta:
        carpeta = args.carpeta
        imp.log(f"\n[1] usando las imagenes de {carpeta}")
    elif args.zip:
        carpeta = os.path.join(args.datos, f"{CFG['origen']}_{CFG['zenodo']}", "imagenes")
        if os.path.exists(os.path.join(carpeta, ".extraido")):
            imp.log(f"\n[1] ya estaban descomprimidas en {carpeta}")
        else:
            libre = shutil.disk_usage(args.datos).free / 1024 ** 3
            if libre < ESPACIO_MIN_GB:
                raise SystemExit(f"hacen falta ~{ESPACIO_MIN_GB:.0f} GB libres y en {args.datos} hay "
                                 f"{libre:.1f} GB. Usa --datos con otra unidad.")
            imp.log("\n[1] Descompresion")
            extraer_zip(args.zip, carpeta)
    else:
        raise SystemExit("Dime donde esta el dataset: --carpeta RUTA (ya descomprimido) o --zip RUTA.zip.\n"
                         "Bajalo a mano de https://data.mendeley.com/datasets/6rj76z6y3n/1 con 'Download All' "
                         "(1.76 GB, CC BY 4.0); este script no lo baja solo.")

    # -- que hay -----------------------------------------------------------------------------
    tomas, sin = indexar(carpeta, patron, args.solo_imagenes)
    n_img = sum(len(t["imagenes"]) for t in tomas.values())
    n_vid = sum(len(t["videos"]) for t in tomas.values())
    clases = sorted({c for c, _p in tomas})
    personas = sorted({p for _c, p in tomas})
    imp.log(f"\n{n_img} imagenes y {n_vid} videos entendidos en {len(tomas)} tomas (clase, persona); "
            f"{len(clases)} clases, {len(personas)} personas; {len(sin)} archivos sin clase o sin persona")
    if sin:
        imp.log("  ejemplos de archivos que no pude entender:")
        for rel, cl, pe in sin[:8]:
            imp.log(f"    {rel}   -> clase={cl} persona={pe}")
        if not tomas:
            raise SystemExit("no entendi ningun archivo. Mira esos nombres y pasa --patron (ver --help).")
        if len(sin) > 0.05 * (n_img + n_vid + len(sin)):
            imp.log("  OJO: mas del 5 % quedo sin clasificar; revisa --listar y --patron")

    mapa, de_donde = leer_clases(carpeta, args.clases)
    if not mapa:
        raise SystemExit("no pude leer el nombre de cada clase (el .xlsx del dataset). Pasa --clases RUTA con "
                         "lineas 'numero,palabra' (.csv o .xlsx).")
    es = leer_nombres_es(args.nombres_es)
    if es:
        n_trad = sum(1 for c in mapa if c in es)
        mapa = {c: es.get(c, p) for c, p in mapa.items()}
        imp.log(f"  nombres en espanol: {n_trad} de {len(mapa)} clases (de {args.nombres_es})")
    else:
        imp.log("  OJO: sin nombres en espanol (no hay " + str(args.nombres_es) + "): las palabras entrarian en INGLES")
    sin_nombre = [c for c in clases if c not in mapa]
    imp.log(f"  nombres de clase: {len(mapa)} (de {de_donde}); clases sin nombre: {len(sin_nombre)}"
            + (f" {sin_nombre[:10]}" if sin_nombre else ""))
    if sin_nombre:
        tomas = {k: v for k, v in tomas.items() if k[0] in mapa}
        imp.log("  (esas clases se omiten: no se inventa el nombre)")
    por_clase = {}
    for (c, p), t in tomas.items():
        por_clase.setdefault(c, []).append(len(t["imagenes"]) or len(t["videos"]))
    imp.log("  personas por clase: min %d, mediana %d, max %d;  cuadros por toma: mediana %d" % (
        min(len(v) for v in por_clase.values()), statistics.median(len(v) for v in por_clase.values()),
        max(len(v) for v in por_clase.values()),
        statistics.median(x for v in por_clase.values() for x in v)))

    if args.listar:
        imp.log("\nPrimeras clases:")
        for c in sorted(por_clase)[:12]:
            ej = next(k for k in sorted(tomas) if k[0] == c)
            t = tomas[ej]
            imp.log(f"  {c:>3} {mapa.get(c, '?'):<22} {len(por_clase[c]):>2} personas   p. ej. "
                    f"{os.path.relpath((t['imagenes'] or t['videos'])[0], carpeta)}")
        imp.log("\n(--listar: termino aqui)")
        return

    # -- filtros -------------------------------------------------------------------------------
    if args.personas.lower() != "todos":
        pe = {int(x) for x in args.personas.split(",") if x.strip()}
        tomas = {k: v for k, v in tomas.items() if k[1] in pe}
    if args.palabras:
        quiero = {a_glosa(x) for x in args.palabras.split(",") if x.strip()}
        tomas = {k: v for k, v in tomas.items() if a_glosa(mapa[k[0]]) in quiero}
    if not tomas:
        raise SystemExit("ninguna toma cumple los filtros")
    lista = sorted(tomas.items())
    if args.probar:
        elegidas = set(elegir_para_probar(list(tomas), args.probar))
        lista = [kv for kv in lista if kv[0] in elegidas]
        imp.log(f"modo prueba: {len(lista)} tomas repartidas entre clases")
    imp.log(f"\n{len(lista)} tomas a procesar, {len({c for (c, _p), _t in lista})} palabras")

    # -- 2: landmarks -> muestras --------------------------------------------------------------
    imp.log("\n[2] Landmarks de cada toma y normalizacion")
    cache = os.path.join(args.datos, f"{CFG['origen']}_{CFG['zenodo']}", "cache")
    muestras = procesar_tomas(lista, mapa, args, cache)
    buenas = [m for m in muestras if not m["motivo"]]
    malas = [m for m in muestras if m["motivo"]]

    ruta_csv = os.path.join(args.datos, "informe_uaemex.csv")
    with open(ruta_csv, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["toma", "clase", "palabra", "glosa", "persona", "fuente", "cuadros", "modo", "validos",
                    "con_mano", "descartada_por", "usados", "recorte_reposo"])
        for m in muestras:
            w.writerow([m["archivo"], m["clase"], m["nombre"], m["gloss"], m["sujeto"], m.get("fuente", ""),
                        m.get("n_frames_video", 0), m.get("modo_cuerpo", ""), f"{m.get('frac_validos', 0):.2f}",
                        f"{m.get('frac_con_mano', 0):.2f}", m["motivo"] or "", m.get("n_frames", 0),
                        "-".join(str(x) for x in m["recorte_reposo"]) if m.get("recorte_reposo") else ""])
    imp.log(f"\n{len(buenas)} tomas buenas, {len(malas)} descartadas  (detalle: {ruta_csv})")
    for m in malas[:12]:
        imp.log(f"  descartada {m['archivo']} ({m['nombre']}): {m['motivo']}")
    if len(malas) > 12:
        imp.log(f"  ... y {len(malas) - 12} mas en el CSV")
    if buenas:
        n_mano = sum(1 for m in buenas if m.get("modo_cuerpo") == "mano")
        imp.log(f"  con cuerpo: {len(buenas) - n_mano} tomas;  solo mano (no se vieron los hombros): {n_mano}")
        imp.log(f"  mano detectada en {statistics.mean(m['frac_con_mano'] for m in buenas):.0%} de los cuadros "
                "validos (promedio)")
        if args.recorte_reposo:
            cu = [m for m in buenas if m.get("modo_cuerpo") != "mano"]
            rec = [m for m in cu if m.get("recorte_reposo")]
            if cu:
                usados = sorted(m["n_frames"] for m in cu)
                imp.log(f"  recorte de reposo: {len(rec)} de {len(cu)} tomas con cuerpo se recortaron; cuadros que "
                        f"quedan por toma: mediana {statistics.median(usados):g}, minimo {usados[0]}, "
                        f"percentil 10 {usados[len(usados) // 10]}, maximo {usados[-1]}")
        por_glosa = {}
        for m in buenas:
            por_glosa.setdefault(m["gloss"], set()).add(m["sujeto"])
        menos = [g for g, s in por_glosa.items() if len(s) < 10]
        imp.log(f"  palabras con >= 10 personas distintas: {len(por_glosa) - len(menos)} de {len(por_glosa)}")
        if menos and not args.probar:
            imp.log("  con menos de 10: " + ", ".join(sorted(menos)[:30]) + (" ..." if len(menos) > 30 else ""))
        if any(m.get("fps_supuesto") for m in buenas):
            imp.log(f"  OJO: las duraciones guardadas usan un ritmo SUPUESTO de {args.fps:g} cuadros por segundo.")

    if args.probar:
        imp.log("\n--- RESULTADO DE LA PRUEBA ---")
        if len(buenas) < max(1, int(0.7 * len(muestras))):
            imp.log("REVISA antes de seguir: menos del 70 % de las tomas salio bien. Mira el CSV "
                    "(prueba --modo mano, --fps, o mira un cuadro a ojo).")
            sys.exit(2)                       # para que un .bat no siga con la importacion completa
        imp.log("Las tomas salen bien. Siguiente paso:  python tools/importar_uaemex.py"
                + (f' --carpeta "{args.carpeta}"' if args.carpeta else f' --zip "{args.zip}"'))
        return

    # -- 3: base ---------------------------------------------------------------------------------
    if args.sin_base or not buenas:
        imp.log("\n(--sin-base: termino aqui)")
        return
    imp.log("\n[3] Base de datos" + ("  (--seco: no se escribe nada)" if args.seco else ""))
    if args.rehacer:
        imp.log("  deshaciendo la importacion anterior:")
        imp.deshacer(CFG, args.datos, seco=args.seco)
    r = imp.importar_a_base(buenas, CFG, args, args.datos)
    imp.log(f"  senas nuevas: {len(r['nuevas'])}   muestras {'a insertar' if args.seco else 'insertadas'}: "
            f"{r['muestras']}  (pendientes: {r['pendientes']}, ya estaban: {r['ya_estaban']})")
    ruta_cred = imp.escribir_creditos(args.datos, CFG)
    imp.log(f"  creditos (licencia {CFG['licencia']}): {ruta_cred}")
    imp.log("\nTodo quedo 'pendiente' y plantillas.json no cambio. Para aprobar hasta 10 grabaciones por palabra:")
    imp.log("    python tools/aprobar_dataset.py --dataset uaemex --por-glosa 10 --existentes sumar --seco")
    imp.log("    python tools/aprobar_dataset.py --dataset uaemex --por-glosa 10 --existentes sumar")


if __name__ == "__main__":
    main()
