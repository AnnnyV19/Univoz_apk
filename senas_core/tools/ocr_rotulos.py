#!/usr/bin/env python3
"""Lee el texto ESCRITO DENTRO DEL VIDEO (rotulos, letras, subtitulos
quemados en la imagen) y arma un <video>.segmentos.csv con la palabra de
cada sena.

    pip install rapidocr onnxruntime        (o:  pip install easyocr)
    python tools/ocr_rotulos.py --video "videos/descargados/algo.mp4"

Es lo que subtitulos.py no puede hacer: un subtitulo que forma parte de la
imagen no viene en ninguna pista aparte, hay que verlo.

COMO FUNCIONA (version 2)

  1. DONDE: se prueba una cuadricula de zonas sobre el video entero, SIN OCR,
     mirando solo la tinta. El rotulo es la zona donde aparece un dibujo FIJO
     (la letra o palabra no se mueve mientras dura), desaparece y luego sale
     otro. La cara, las manos y la ropa se mueven, asi que no engañan; un
     logo siempre esta, asi que tampoco. Las mejores zonas se prueban con OCR
     y se queda la que de verdad se puede leer como texto.
  2. CUANDO: se sigue esa zona a 5 cuadros por segundo: hay rotulo / no hay /
     cambio por otro. Los cortes salen de ahi, son exactos y no dependen de que
     el OCR acierte en cada cuadro.
  3. QUE DICE: el OCR se aplica una vez por tramo (3 cuadros del medio,
     ampliados, y se vota). Una letra suelta tambien se lee.

Con --roi x0,y0,x1,y1 (fracciones 0..1) te saltas el paso 1. En la pagina es
el boton «Marcar dónde sale la letra» + «Leer en esa zona».

Si el lector de texto no logra leer las letras pero la zona es clara (muchos
rotulos fijos que cambian), los CORTES se dejan igual con la palabra vacia: los
cortes son buenos y la palabra se escribe viendo cada clip.

LIMITES: el OCR se equivoca con letras decoradas o muy chicas, y puede perder
acentos y la ñ. Es una propuesta: en la pagina ves cada clip y corriges.
"""

import argparse
import atexit
import hashlib
import os
import re
import shutil
import sys
import tempfile
import unicodedata
from collections import Counter, namedtuple

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, AQUI)

import segmentos_csv  # noqa: E402

# Una linea de texto leida: confianza 0..1, caja en fracciones de la imagen.
Linea = namedtuple("Linea", "texto conf x0 y0 x1 y1")

# Un tramo de tinta fija hallado al buscar la zona: inicio, fin, parecido medio
# entre cuadros seguidos, indices de muestras, y cuantos pares de cuadros
# seguidos son IDENTICOS (iou >= 0.99) del total.
Fijo = namedtuple("Fijo", "a b media idx firmes pares")


# ---------------------------------------------------------------- motor OCR


class Motor:
    """Un OCR detras de dos funciones:

        leer(imagen)        -> [Linea]   detecta y lee todo el texto
        leer_recorte(img)   -> [Linea]   la imagen ES una linea/letra: solo
                                         reconoce (sirve para una letra sola,
                                         que el detector a veces no ve)

    Prueba rapidocr (el nuevo y el viejo) y despues easyocr."""

    def __init__(self):
        self.nombre = None
        self.error = None
        self._f = None
        self._rec = None
        for intento in (self._rapidocr_nuevo, self._rapidocr_viejo, self._easyocr):
            try:
                if intento():
                    return
            except Exception:
                continue

    @staticmethod
    def _caja(puntos, h, w):
        xs = [p[0] for p in puntos]
        ys = [p[1] for p in puntos]
        return min(xs) / w, min(ys) / h, max(xs) / w, max(ys) / h

    def _rapidocr_nuevo(self):
        from rapidocr import RapidOCR  # paquete "rapidocr" (v2 en adelante)
        try:
            from rapidocr import LangRec
            motor = RapidOCR(params={"Rec.lang_type": LangRec.LATIN})
        except Exception:
            motor = RapidOCR()

        def convertir(r, h, w):
            if r is None or getattr(r, "txts", None) is None:
                return []
            cajas = getattr(r, "boxes", None)
            out = []
            for i, (txt, sc) in enumerate(zip(r.txts, r.scores)):
                if cajas is not None and i < len(cajas):
                    x0, y0, x1, y1 = self._caja(cajas[i], h, w)
                else:
                    x0, y0, x1, y1 = 0.0, 0.0, 1.0, 1.0
                out.append(Linea(str(txt), float(sc), x0, y0, x1, y1))
            return out

        def leer(img):
            return convertir(motor(img), img.shape[0], img.shape[1])

        def leer_recorte(img):
            return convertir(motor(img, use_det=False, use_cls=False, use_rec=True),
                             img.shape[0], img.shape[1])
        self._f, self._rec, self.nombre = leer, leer_recorte, "rapidocr"
        return True

    def _rapidocr_viejo(self):
        from rapidocr_onnxruntime import RapidOCR  # paquete anterior
        motor = RapidOCR()

        def leer(img):
            res, _ = motor(img)
            h, w = img.shape[:2]
            return [Linea(str(t), float(s), *self._caja(c, h, w))
                    for c, t, s in (res or [])]

        def leer_recorte(img):
            res, _ = motor(img, use_det=False, use_cls=False, use_rec=True)
            return [Linea(str(t), float(s), 0.0, 0.0, 1.0, 1.0)
                    for _, t, s in (res or [])]
        self._f, self._rec, self.nombre = leer, leer_recorte, "rapidocr (anterior)"
        return True

    def _easyocr(self):
        import easyocr
        lector = easyocr.Reader(["es"], gpu=False, verbose=False)

        def leer(img):
            h, w = img.shape[:2]
            return [Linea(str(t), float(s), *self._caja(c, h, w))
                    for c, t, s in lector.readtext(img)]
        self._f, self._rec, self.nombre = leer, None, "easyocr"
        return True

    @property
    def listo(self):
        return self._f is not None

    def leer(self, img):
        # Un cuadro que haga fallar al lector no debe tirar toda la corrida.
        try:
            return self._f(img)
        except Exception as e:      # noqa: BLE001
            self.error = e
            return []

    def probar(self):
        """Lee una imagen de prueba (la letra A). -> (True, None) o (False, error).
        Sirve para avisar claro si el lector esta mal instalado o no pudo bajar
        sus modelos, en vez de terminar diciendo 'no pude leer nada'."""
        import cv2
        import numpy as np
        img = np.full((120, 160, 3), 255, np.uint8)
        cv2.putText(img, "A", (45, 95), cv2.FONT_HERSHEY_SIMPLEX, 3.2, (0, 0, 0), 8)
        try:
            self._f(img)
            return True, None
        except Exception as e:      # noqa: BLE001
            return False, f"{type(e).__name__}: {e}"

    def leer_recorte(self, img):
        if self._rec is None:
            return []
        try:
            return self._rec(img)
        except Exception:
            return []


# ----------------------------------------------------------------- logica


def clave(texto):
    """Texto comparable: sin acentos, minusculas, solo letras y numeros."""
    t = unicodedata.normalize("NFD", texto.lower())
    t = "".join(c for c in t if unicodedata.category(c) != "Mn")
    return re.sub(r"[^a-z0-9ñ ]+", " ", t).strip()


def util(linea, min_conf):
    """Una linea sirve si tiene confianza y al menos un caracter de verdad.

    Una sola letra SI sirve (en un abecedario todo el rotulo es una letra);
    pero como una letra suelta es lo que el OCR inventa mas facil con manchas
    y bordes, se le pide un poco mas de confianza que a una palabra."""
    k = clave(linea.texto)
    if not k:
        return False
    return linea.conf >= (min_conf + 0.1 if len(k) == 1 else min_conf)


def texto_de(lineas, min_conf=0.5):
    """Junta de arriba abajo (y de izquierda a derecha) las lineas utiles.
    Devuelve (texto, confianza) o (None, 0). Si dos lineas dicen lo mismo
    (el mismo texto leido por dos caminos) se queda una."""
    buenas = [l for l in lineas if util(l, min_conf)]
    if not buenas:
        return None, 0.0
    buenas.sort(key=lambda l: (round((l.y0 + l.y1) / 2, 1), l.x0))
    vistas, unicas = set(), []
    for l in buenas:
        k = clave(l.texto)
        if k not in vistas:
            vistas.add(k)
            unicas.append(l)
    return (" ".join(l.texto.strip() for l in unicas),
            sum(l.conf for l in unicas) / len(unicas))


# ------------------------------------------------------- donde esta el rotulo

# Tamaños (ancho, alto) de zona, en fracciones de la imagen: desde una letra
# chica hasta una franja de subtitulo. Cada tamaño se desliza de a medio paso.
TAMANOS_ZONA = [(0.08, 0.14), (0.12, 0.22), (0.20, 0.30), (0.30, 0.15),
                (0.45, 0.12), (0.60, 0.18)]

# Parecido medio (IoU de la tinta) entre cuadros seguidos de un MISMO tramo.
# Un rotulo es un dibujo fijo: ~0.99. Una mano o una cara en movimiento
# queda en 0.5-0.9. Es lo que separa una cosa de la otra.
ESTABLE_MIN = 0.92


def zonas():
    """Genera rectangulos (x0, y0, x1, y1) que cubren toda la imagen."""
    for w, h in TAMANOS_ZONA:
        x = 0.0
        while x + w <= 1.0001:
            y = 0.0
            while y + h <= 1.0001:
                yield (round(x, 3), round(y, 3),
                       round(min(1.0, x + w), 3), round(min(1.0, y + h), 3))
                y += h / 2
            x += w / 2


def _area(r):
    return (r[2] - r[0]) * (r[3] - r[1])


def _expandir(r, f):
    """Agranda el rectangulo f veces su tamaño por cada lado."""
    dx, dy = (r[2] - r[0]) * f, (r[3] - r[1]) * f
    return (max(0.0, r[0] - dx), max(0.0, r[1] - dy),
            min(1.0, r[2] + dx), min(1.0, r[3] + dy))


def _solapan(a, b, max_frac=0.25):
    """True si dos zonas comparten mas de max_frac de la mas chica."""
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    return ix * iy > max_frac * min(_area(a), _area(b))


def muestras_zona(grises, roi, ancho=64):
    """[(t, mascara_de_tinta | None)] de esa zona en cada cuadro."""
    import cv2
    x0, y0, x1, y1 = roi
    out = []
    for t, g in grises:
        h, w = g.shape[:2]
        rec = g[int(y0 * h): max(int(y0 * h) + 2, int(y1 * h)),
                int(x0 * w): max(int(x0 * w) + 2, int(x1 * w))]
        if rec.size == 0:
            out.append((t, None))
            continue
        rec = cv2.resize(rec, (ancho, max(8, int(ancho * rec.shape[0] / rec.shape[1]))))
        out.append((t, mascara_tinta(rec)))
    return out


def tramos_estables(muestras, paso, min_dur=1.0, max_dur=20.0, estable_min=ESTABLE_MIN):
    """Tramos de tinta FIJA -> [Fijo]."""
    out = []
    for a, b, idx in tramos_por_tinta(muestras, paso, min_dur=min_dur):
        if b - a > max_dur or len(idx) < 3:
            continue
        ious = [iou(muestras[idx[k]][1], muestras[idx[k + 1]][1])
                for k in range(len(idx) - 1)]
        media = sum(ious) / len(ious) if ious else 1.0
        if media >= estable_min:
            out.append(Fijo(a, b, media, idx,
                            sum(1 for v in ious if v >= 0.99), len(ious)))
    return out


def puntuar_zona(grises, paso, roi, duracion):
    """-> (puntaje, [Fijo]).

    Puntaje = cuantos rotulos fijos hay en la zona x que parte del video
    ocupan x que tan IDENTICOS se quedan mientras duran.

    Lo ultimo es lo que separa un rotulo de una persona: una letra puesta
    encima del video no se mueve ni un pixel (casi todos los pares de cuadros
    seguidos dan iou 1.0), mientras que una persona "quieta", una mano o la
    ropa siempre se mueven un poco (iou 0.95-0.98). Medido en videos reales:
    rotulos 0.8-0.94 de pares identicos, personas 0.04-0.46.

    Con menos de 3 tramos no hay patron (un titulo o un logo salen una o dos
    veces) y vale 0."""
    est = tramos_estables(muestras_zona(grises, roi), paso)
    if len(est) < 3:
        return 0.0, est
    cob = sum(t.b - t.a for t in est) / max(duracion, 1e-6)
    pares = sum(t.pares for t in est)
    firmes = (sum(t.firmes for t in est) / pares) if pares else 1.0
    return len(est) * min(cob, 0.8) * firmes ** 2, est


def ajustar_zona(grises, roi, est, aire=0.3):
    """Encoge la zona a donde esta la letra o palabra (mas un poco de aire).

    Se compara, pixel por pixel, cuanta tinta hay MIENTRAS el rotulo esta
    puesto contra cuanta hay cuando no esta. El rotulo es lo que solo existe
    durante sus tramos; el hombro, la cabeza o la ropa estan igual en los
    dos casos y se cancelan. Un recorte pegado a la letra se lee mejor y
    separa mejor un rotulo del siguiente."""
    import cv2
    import numpy as np
    x0, y0, x1, y1 = roi
    tintas = []
    for t, g in grises:
        h, w = g.shape[:2]
        rec = g[int(y0 * h): max(int(y0 * h) + 2, int(y1 * h)),
                int(x0 * w): max(int(x0 * w) + 2, int(x1 * w))]
        rec = cv2.resize(rec, (64, max(8, int(64 * rec.shape[0] / rec.shape[1]))))
        tintas.append(_tinta_otsu(rec)[0])
    dentro = np.zeros(len(grises), bool)
    cerca = np.zeros(len(grises), bool)
    for tr in est:
        for i in tr.idx:
            dentro[i] = True
        for i, (t, _) in enumerate(grises):
            if tr.a - 0.5 <= t <= tr.b + 0.5:
                cerca[i] = True
    fuera = ~cerca
    if dentro.sum() < 3 or fuera.sum() < 5:
        return roi
    pila = np.stack(tintas).astype(np.float32)
    dif = pila[dentro].mean(axis=0) - pila[fuera].mean(axis=0)
    if dif.max() < 0.05:
        return roi
    cambia = (dif >= max(0.05, 0.25 * dif.max())).astype(np.uint8)
    cambia = cv2.dilate(cambia, np.ones((3, 3), np.uint8))
    n, etiquetas, stats, _ = cv2.connectedComponentsWithStats(cambia)
    if n <= 1:
        return roi
    # El bloque del rotulo es el de mas diferencia acumulada.
    masas = [float(dif[etiquetas == k].clip(0).sum()) for k in range(1, n)]
    principal = 1 + masas.index(max(masas))
    px0, py0 = stats[principal, cv2.CC_STAT_LEFT], stats[principal, cv2.CC_STAT_TOP]
    pw, ph = stats[principal, cv2.CC_STAT_WIDTH], stats[principal, cv2.CC_STAT_HEIGHT]
    # Una palabra puede quedar en varios bloques (letras separadas): se suman
    # los que estan pegados al principal, no los lejanos.
    grandes = [principal]
    for k in range(1, n):
        if k == principal or masas[k - 1] < 0.1 * max(masas):
            continue
        kx, ky = stats[k, cv2.CC_STAT_LEFT], stats[k, cv2.CC_STAT_TOP]
        kw, kh = stats[k, cv2.CC_STAT_WIDTH], stats[k, cv2.CC_STAT_HEIGHT]
        if (kx < px0 + pw + 0.5 * pw and kx + kw > px0 - 0.5 * pw
                and ky < py0 + ph + 0.5 * ph and ky + kh > py0 - 0.5 * ph):
            grandes.append(k)
    bx0 = min(stats[k, cv2.CC_STAT_LEFT] for k in grandes)
    by0 = min(stats[k, cv2.CC_STAT_TOP] for k in grandes)
    bx1 = max(stats[k, cv2.CC_STAT_LEFT] + stats[k, cv2.CC_STAT_WIDTH] for k in grandes)
    by1 = max(stats[k, cv2.CC_STAT_TOP] + stats[k, cv2.CC_STAT_HEIGHT] for k in grandes)
    hh, ww = cambia.shape
    ax0, ax1 = x0 + bx0 / ww * (x1 - x0), x0 + bx1 / ww * (x1 - x0)
    ay0, ay1 = y0 + by0 / hh * (y1 - y0), y0 + by1 / hh * (y1 - y0)
    px, py = (ax1 - ax0) * aire + 0.004, (ay1 - ay0) * aire + 0.004
    return (round(max(0.0, ax0 - px), 4), round(max(0.0, ay0 - py), 4),
            round(min(1.0, ax1 + px), 4), round(min(1.0, ay1 + py), 4))


def _tinta_otsu(gris):
    """(mascara de tinta, fraccion, separacion): la clase MINORITARIA tras
    Otsu. La separacion es la diferencia de gris entre tinta y fondo."""
    import cv2
    import numpy as np
    _, m = cv2.threshold(gris, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    claro = m > 0
    tinta = ~claro if claro.mean() > 0.5 else claro
    frac = float(tinta.mean())
    if tinta.all() or (~tinta).all():
        return np.asarray(tinta), frac, 0.0
    sep = abs(float(gris[tinta].mean()) - float(gris[~tinta].mean()))
    return np.asarray(tinta), frac, sep


def mascara_tinta(gris, min_sep=60.0, rango=(0.008, 0.6)):
    """Mascara booleana de la tinta si en este recorte hay un rotulo, o None.

    Un recorte de fondo liso se parte en dos al azar: lo que lo delata es que
    las dos mitades son casi del mismo gris (separacion baja). Un rotulo
    real separa mucho (letra oscura sobre fondo claro, o al reves)."""
    tinta, frac, sep = _tinta_otsu(gris)
    if not (rango[0] <= frac <= rango[1]) or sep < min_sep:
        return None
    return tinta


def iou(a, b):
    union = (a | b).sum()
    return float((a & b).sum() / union) if union else 1.0


def tramos_por_tinta(muestras, paso, iou_seguido=0.88, iou_tras_hueco=0.95,
                     hueco_max=0.7, min_dur=0.6):
    """muestras: [(t, mascara|None)] -> [(inicio, fin, [indices de muestras])].

    Un tramo es una racha de muestras CON rotulo cuya tinta no cambia. Se
    corta cuando:
      - la tinta cambia (otra letra): cada muestra se compara con la anterior;
      - el rotulo desaparece y vuelve con OTRO dibujo. Un hueco corto es el
        mismo rotulo parpadeando, y se le exige que vuelva casi igual. Esto
        importa: dos letras seguidas se parecen (i y j, m y n) y con un
        umbral flojo se fundian en una sola sena;
      - el hueco pasa de hueco_max segundos.
    Los cuadros de las transiciones (el rotulo a medio desvanecerse) no se
    parecen a nada y quedan en tramos de 1 muestra que min_dur tira."""
    grupos = []
    actual = None
    for i, (t, m) in enumerate(muestras):
        if m is None:
            continue
        if actual is not None:
            j = actual["idx"][-1]
            tj, mj = muestras[j]
            hueco = t - tj > paso * 1.5
            umbral = iou_tras_hueco if hueco else iou_seguido
            seguir = (t - tj <= hueco_max + paso and mj.shape == m.shape
                      and iou(mj, m) >= umbral)
        else:
            seguir = False
        if seguir:
            actual["idx"].append(i)
        else:
            actual = {"idx": [i]}
            grupos.append(actual)
    out = []
    for g in grupos:
        a = muestras[g["idx"][0]][0]
        b = muestras[g["idx"][-1]][0] + paso
        if b - a >= min_dur:
            out.append((a, b, g["idx"]))
    return out


def votar(lecturas):
    """lecturas: [(texto, conf)] de varios cuadros del mismo tramo -> la mas
    repetida (con su confianza media), o (None, 0)."""
    buenas = [(t, c) for t, c in lecturas if t]
    if not buenas:
        return None, 0.0
    cuenta = Counter(clave(t) for t, _ in buenas)
    k, _ = cuenta.most_common(1)[0]
    elegidas = [(t, c) for t, c in buenas if clave(t) == k]
    # entre las variantes con la misma clave, el texto de mayor confianza
    texto = max(elegidas, key=lambda x: x[1])[0].strip()
    return texto, sum(c for _, c in elegidas) / len(elegidas)


def quitar_titulos(tramos, log=print):
    """En un abecedario cada rotulo es una letra (1-2 caracteres). Un tramo
    cuyo texto es mucho mas largo que el normal es el titulo o los creditos del
    video, no una sena. Solo actua cuando la gran mayoria son textos cortos."""
    largos = [len(clave(t).replace(" ", "")) for _, _, t, _ in tramos if t]
    if len(largos) < 6:
        return tramos
    largos_ord = sorted(largos)
    mediana = largos_ord[len(largos_ord) // 2]
    if mediana > 2:
        return tramos
    fuera = [x for x in tramos if x[2] and len(clave(x[2]).replace(" ", "")) > 6]
    if fuera:
        log(f"  quito {len(fuera)} tramo(s) con texto largo (titulo o creditos): "
            + ", ".join(repr(x[2][:30]) for x in fuera[:3]))
    return [x for x in tramos if x not in fuera]


def quitar_estaticos(tramos, duracion_video, max_presencia=0.35):
    """Tira el texto que esta en pantalla gran parte del video (logo, nombre
    del canal): no es la palabra de ninguna sena."""
    if not duracion_video:
        return tramos
    tiempo = Counter()
    for a, b, t, _ in tramos:
        if t:
            tiempo[clave(t)] += b - a
    return [x for x in tramos
            if not x[2] or tiempo[clave(x[2])] / duracion_video <= max_presencia]


# -------------------------------------------------------------------- video


def _cuadros(cv2, video, cada_s):
    """Genera (t_segundos, imagen, duracion) cada `cada_s` segundos leyendo en
    secuencia (saltar con set() es lento en mp4)."""
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        sys.exit(f"no pude abrir el video: {video}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    n = cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0
    paso = max(1, int(round(fps * cada_s)))
    i = 0
    try:
        while True:
            if not cap.grab():
                break
            if i % paso == 0:
                ok, img = cap.retrieve()
                if ok:
                    yield i / fps, img, (n / fps if n else None)
            i += 1
    finally:
        cap.release()


def _ruta_abrible(video):
    """Ruta con la que OpenCV SI puede abrir el video.

    En Windows OpenCV abre las rutas con la pagina de codigos ANSI del sistema
    (cp1252 en español). Un caracter que no cabe ahi -- por ejemplo la barra
    ancha "｜" que yt-dlp pone en el nombre en lugar de "|" -- hace que diga
    que no puede abrir el video aunque el archivo exista. En ese caso se abre
    una copia con nombre simple en la carpeta temporal."""
    if sys.platform != "win32":
        return video
    try:
        video.encode("mbcs")
        return video
    except (UnicodeEncodeError, LookupError):
        pass
    copia = os.path.join(
        tempfile.gettempdir(),
        "univoz_" + hashlib.md5(video.encode("utf-8")).hexdigest()[:10]
        + os.path.splitext(video)[1])
    if not (os.path.exists(copia) and os.path.getsize(copia) == os.path.getsize(video)):
        print("  (el nombre del video tiene un caracter que OpenCV no abre en Windows: "
              "trabajo con una copia temporal)")
        try:
            os.link(video, copia)
        except OSError:
            shutil.copyfile(video, copia)

    def borrar():
        try:
            os.remove(copia)
        except OSError:
            pass
    atexit.register(borrar)
    return copia


def _duracion(video):
    import cv2
    cap = cv2.VideoCapture(video)
    try:
        n = cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0
        fps = cap.get(cv2.CAP_PROP_FPS) or 0
        return n / fps if n and fps else None
    finally:
        cap.release()


def cargar_grises(video, fps=4.0, ancho=256):
    """Video entero en gris y chico (para puntuar zonas sin releerlo)."""
    import cv2
    out, dur = [], None
    for t, img, d in _cuadros(cv2, video, 1.0 / fps):
        dur = d or dur
        g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        h, w = g.shape[:2]
        out.append((t, cv2.resize(g, (ancho, max(8, int(ancho * h / w))))))
    return out, dur


def localizar(video, max_zonas=8, log=print):
    """Paso 1: zonas donde hay un rotulo fijo que cambia. Sin OCR.

    -> ([{"roi", "puntaje", "tramos": [(inicio, fin)]}], duracion), de la mejor
    a la peor. Son CANDIDATAS: elegir_por_ocr se queda con la que se lee."""
    dur0 = _duracion(video)
    # 3 cuadros por segundo; en un video largo menos, para que no tarde horas
    # (un rotulo dura segundos: 2 por segundo todavia lo ve de sobra).
    fps = 3.0 if not dur0 or dur0 <= 300 else max(2.0, 900.0 / dur0)
    if dur0 and dur0 > 600:
        log(f"  video largo ({dur0 / 60:.0f} min): buscar la zona va a tardar unos minutos...")
    grises, dur = cargar_grises(video, fps=fps)
    if len(grises) < 10:
        return [], dur
    paso = 1.0 / fps
    dur = dur or grises[-1][0]
    puntuadas = []
    for roi in zonas():
        p, est = puntuar_zona(grises, paso, roi, dur)
        if p > 0:
            puntuadas.append((p, roi, est))
    # A igual puntaje gana la zona mas chica (mas pegada al rotulo).
    puntuadas.sort(key=lambda r: (-round(r[0], 1), _area(r[1])))
    out = []
    for p, roi, est in puntuadas:
        if any(_solapan(roi, o["zona"]) for o in out):
            continue
        # Dos pasadas: la zona de la cuadricula puede cortar la letra por un
        # lado; se ajusta, se agranda un poco y se ajusta de nuevo.
        ajustada = ajustar_zona(grises, roi, est)
        ajustada = ajustar_zona(grises, _expandir(ajustada, 0.6), est, aire=0.2)
        out.append({"zona": roi, "roi": ajustada,
                    "puntaje": p, "tramos": [(t.a, t.b) for t in est]})
        if len(out) >= max_zonas:
            break
    return out, dur


def _leer_en(cap, cv2, motor, roi, t, min_conf):
    """Lee la zona en el instante t -> texto | None"""
    cap.set(cv2.CAP_PROP_POS_MSEC, t * 1000.0)
    ok, img = cap.read()
    if not ok:
        return None
    h, w = img.shape[:2]
    x0, y0, x1, y1 = roi
    rec = img[int(y0 * h): int(y1 * h), int(x0 * w): int(x1 * w)]
    if rec.size == 0:
        return None
    return texto_de(_leer_ampliado(cv2, motor, rec), min_conf)[0]


def elegir_por_ocr(video, motor, candidatas, min_conf=0.5, n=6, log=print):
    """De las zonas candidatas, la que mejor se LEE como texto.

    Se lee un cuadro de n tramos repartidos por zona. -> (roi, textos) o
    (None, [])."""
    import cv2
    cap = cv2.VideoCapture(video)
    mejor, mejores = None, []
    try:
        for k, c in enumerate(candidatas, start=1):
            tr = c["tramos"]
            paso = max(1, len(tr) // n)
            probados = tr[::paso][:n]
            leidos = [t for t in (_leer_en(cap, cv2, motor, c["roi"], (a + b) / 2, min_conf)
                                  for a, b in probados) if t]
            r = c["roi"]
            log(f"  zona {k}: x {r[0]:.2f}-{r[2]:.2f}, y {r[1]:.2f}-{r[3]:.2f}  "
                f"{len(tr)} cambios fijos, se leyeron {len(leidos)} de {len(probados)}"
                + (f"  ({', '.join(leidos[:6])})" if leidos else ""))
            if len(leidos) > len(mejores):
                mejor, mejores = r, leidos
            if len(leidos) >= 4 and len(leidos) >= 0.6 * len(probados):
                break           # esta ya es clara: no se gasta mas OCR
    finally:
        cap.release()
    if mejor is None or len(mejores) < 2:
        return None, []
    return mejor, mejores


def _quitar_fijo(crudas, max_presencia=0.85, min_px=6):
    """crudas: [(t, tinta|None)] -> [(t, mascara|None)].

    Lo que es tinta en casi todos los cuadros (un hombro, la ropa, un marco)
    no es el rotulo: se borra de todas las mascaras. Si despues de borrarlo no
    queda nada, en ese cuadro no hay rotulo. Asi una zona que roza a la
    persona no se confunde con un rotulo cada vez que ella se mueve."""
    import cv2
    import numpy as np
    validas = [m for _, m in crudas if m is not None]
    if len(validas) < 20:
        return crudas
    fijo = np.stack(validas).astype(np.float32).mean(axis=0) > max_presencia
    if not fijo.any():
        return crudas
    nucleo = np.ones((3, 3), np.uint8)
    out = []
    for t, m in crudas:
        if m is None:
            out.append((t, None))
            continue
        r = (m & ~fijo).astype(np.uint8)
        r = cv2.morphologyEx(r, cv2.MORPH_OPEN, nucleo)   # fuera lo flaco
        out.append((t, r.astype(bool) if r.sum() >= min_px else None))
    return out


def rastrear(video, roi, fps=5.0):
    """Paso 2: sigue la zona cuadro a cuadro, sin OCR.
    -> (tramos [(inicio, fin, [indices])], recortes (JPEG por cuadro), duracion)"""
    import cv2
    x0, y0, x1, y1 = roi
    paso = 1.0 / fps
    crudas, recortes = [], []
    dur = None
    for t, img, d in _cuadros(cv2, video, paso):
        dur = d or dur
        h, w = img.shape[:2]
        rec = img[int(y0 * h): int(y1 * h), int(x0 * w): int(x1 * w)]
        if rec.size == 0:
            crudas.append((t, None))
            recortes.append(None)
            continue
        g = cv2.cvtColor(rec, cv2.COLOR_BGR2GRAY)
        g = cv2.resize(g, (96, max(8, int(96 * g.shape[0] / g.shape[1]))))
        tinta, frac, sep = _tinta_otsu(g)
        crudas.append((t, tinta if (sep >= 60.0 and frac >= 0.008) else None))
        # JPEG en memoria: guardar ~1500 recortes sin comprimir son cientos de MB.
        ok, buf = cv2.imencode(".jpg", rec, [cv2.IMWRITE_JPEG_QUALITY, 92])
        recortes.append(buf if ok else None)
    muestras = _quitar_fijo(crudas)
    # 0.8 s: la cola de un rotulo que se desvanece dura ~0.6 s y no es una sena.
    return tramos_por_tinta(muestras, paso, min_dur=0.8), recortes, dur


def seguir(video, motor, roi, fps=5.0, min_conf=0.5, log=print):
    """Pasos 2 y 3: cortes por tinta + OCR por tramo. -> (tramos, duracion)"""
    import cv2
    tramos, recortes, dur = rastrear(video, roi, fps)
    log(f"  {len(tramos)} tramo(s) con rotulo; leyendo cada uno...")

    out = []
    for a, b, idx in tramos:
        # tres cuadros del medio: los de los bordes son los de la transicion
        n = len(idx)
        elegidos = sorted({idx[n // 2], idx[max(0, n // 3)], idx[min(n - 1, (2 * n) // 3)]})
        lecturas = []
        for j in elegidos:
            if recortes[j] is None:
                continue
            img = cv2.imdecode(recortes[j], cv2.IMREAD_COLOR)
            lecturas.append(texto_de(_leer_ampliado(cv2, motor, img), min_conf))
        texto, conf = votar(lecturas)
        out.append((a, b, texto or "", conf if texto else None))
    return quitar_titulos(quitar_estaticos(out, dur), log), dur


def _binarizada(cv2, img):
    """Tinta negra sobre fondo blanco, sin colores ni degradados. Una letra
    morada sobre fondo rosa se ve bien para una persona y mal para un OCR."""
    import numpy as np
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    tinta, frac, sep = _tinta_otsu(g)
    if sep < 40 or not (0.005 <= frac <= 0.7):
        return None
    out = np.full(g.shape, 255, np.uint8)
    out[tinta] = 0
    return cv2.cvtColor(out, cv2.COLOR_GRAY2BGR)


def _leer_ampliado(cv2, motor, img):
    """Un rotulo chico se lee mejor ampliado y con aire alrededor. Se prueba
    con el color original y, si no sale nada, en blanco y negro puro. Si el
    detector sigue sin ver nada (pasa con una sola letra), se intenta
    reconocer el recorte entero como si fuera una linea."""
    h, w = img.shape[:2]
    k = max(1.0, 96.0 / max(1, h))
    if k > 1.0:
        img = cv2.resize(img, (int(w * k), int(h * k)), interpolation=cv2.INTER_CUBIC)
    borde = int(0.15 * max(img.shape[:2]))
    relleno = cv2.copyMakeBorder(img, borde, borde, borde, borde,
                                 cv2.BORDER_REPLICATE)
    variantes = [relleno]
    bn = _binarizada(cv2, relleno)
    if bn is not None:
        variantes.append(bn)
    lineas = []
    for v in variantes:
        lineas = motor.leer(v)
        if any(util(l, 0.4) for l in lineas):
            return lineas
    for v in reversed(variantes):          # primero el limpio
        lineas = lineas + motor.leer_recorte(v)
    return lineas


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", required=True)
    ap.add_argument("--roi", help="x0,y0,x1,y1 en fracciones; sin esto se busca solo")
    ap.add_argument("--fps", type=float, default=5.0)
    ap.add_argument("--min-conf", type=float, default=0.5)
    ap.add_argument("--esperado", type=int,
                    help="cuantas senas trae el video (solo para avisar si no cuadra)")
    ap.add_argument("--margen", type=float, default=0.3,
                    help="se ensancha cada tramo esto de cada lado (default 0.3 s)")
    ap.add_argument("--categoria")
    args = ap.parse_args()

    if not os.path.exists(args.video):
        sys.exit(f"no existe el video: {args.video}")

    abrible = _ruta_abrible(args.video)

    motor = Motor()
    if not motor.listo:
        sys.exit("falta un lector de texto (OCR):  pip install rapidocr onnxruntime\n"
                 "                                  o:  pip install easyocr")
    ok, error = motor.probar()
    if not ok:
        sys.exit(f"el lector de texto ({motor.nombre}) esta instalado pero falla: {error}\n"
                 "   La primera vez baja sus modelos de internet; si no hay conexion, o si\n"
                 "   se instalo a medias, reinstala:  pip install -U rapidocr onnxruntime")
    print(f"  lector de texto: {motor.nombre}")

    roi = None
    if args.roi:
        try:
            roi = tuple(float(x) for x in args.roi.split(","))
            assert len(roi) == 4 and roi[0] < roi[2] and roi[1] < roi[3]
        except (ValueError, AssertionError):
            sys.exit("--roi tiene que ser x0,y0,x1,y1 en fracciones (x0<x1, y0<y1)")
    else:
        print("  paso 1: buscando donde aparece un rotulo fijo que cambia...")
        cands, _ = localizar(abrible)
        if not cands:
            sys.exit("no encontre ninguna zona con rotulos que aparezcan y cambien: "
                     "este video no parece traer letras o palabras escritas "
                     "(o salen muy poco rato)")
        roi, leidos = elegir_por_ocr(abrible, motor, cands, args.min_conf)
        if roi is None:
            # Aun sin leer nada, una zona con muchos rotulos fijos y parejos
            # es casi seguro el rotulo: los CORTES sirven aunque falte la
            # palabra (se escribe viendo cada clip), y son mejores que
            # cortar por imagen.
            mejor = cands[0]
            if mejor["puntaje"] >= 8 and len(mejor["tramos"]) >= 8:
                roi = mejor["roi"]
                print(f"\n  OJO: hay {len(mejor['tramos'])} rotulos fijos que cambian, "
                      "pero el lector de texto no reconocio las letras.\n"
                      "       Dejo los cortes igual; escribe la palabra viendo cada clip.")
            else:
                sys.exit("encontre zonas donde aparece algo que cambia, pero el "
                         "lector de texto no pudo leer ninguna: no parece texto")
        # La pagina lee esta linea para dibujar la zona sobre el video.
        print(f"  zona del rotulo: x {roi[0]:.2f}-{roi[2]:.2f}, y {roi[1]:.2f}-{roi[3]:.2f}")

    print("  paso 2: siguiendo el rotulo cuadro a cuadro...")
    tramos, dur = seguir(abrible, motor, roi, args.fps, args.min_conf)
    if not tramos:
        sys.exit("no encontre ningun rotulo en esa zona")

    tramos = segmentos_csv.normalizar_tramos(
        [(a - args.margen, b + args.margen, t, c) for a, b, t, c in tramos],
        0.8, dur)
    filas = [{"inicio_s": a, "fin_s": b, "palabra": t, "categoria": args.categoria,
              "fuente": "texto" if t else "imagen", "confianza": c}
            for a, b, t, c in tramos]
    ruta = segmentos_csv.escribir(args.video, filas)

    con = sum(1 for f in filas if f["palabra"])
    print(f"\n{len(filas)} tramo(s), {con} con texto leido:")
    for k, f in enumerate(filas[:60], start=1):
        conf = "" if f["confianza"] is None else f"  ({f['confianza']:.0%})"
        print(f"  #{k:<3} {f['inicio_s']:7.2f} - {f['fin_s']:7.2f}  "
              f"{f['palabra'][:50] or '(no pude leerlo)'}{conf}")
    if len(filas) > 60:
        print(f"  ... y {len(filas) - 60} mas")
    if args.esperado and abs(len(filas) - args.esperado) > max(1, args.esperado // 10):
        print(f"\n  OJO: esperabas {args.esperado} senas y encontre {len(filas)}.")
    print(f"\n  {ruta}")
    print("\nEl OCR se equivoca con acentos y letras raras: revisa cada palabra.")


if __name__ == "__main__":
    main()
