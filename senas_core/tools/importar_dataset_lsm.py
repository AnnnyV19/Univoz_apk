#!/usr/bin/env python3
"""Importa un dataset publico de Lengua de Senas Mexicana al diccionario.

Hace TODO el camino, con el mismo pipeline que ya usas para tus videos
(extraer_landmarks.py -> sign_norm.py -> base -> exportar_paquete.py):

  1. baja el dataset de Zenodo (con reanudacion si se corta) y verifica el MD5
  2. lo descomprime
  3. saca los landmarks de cada video y los normaliza (2.0.0, 32 x 152)
  4. descarta tomas malas (sin hombros, sin manos) y recorta el video como lo
     haria la app en vivo: desde que se mueven las manos hasta ~0.7 s quietas
     (los videos de 60 fps se bajan a 30 antes)
  5. hace una prueba entre las dos personas expertas: una firma, la otra
     reconoce -> te dice si las plantillas del dataset sirven para RECONOCER
     (resultado con los videos reales: casi no; si sirven para que el avatar
     ensene la sena)
  6. lo sube a la base como origen 'video'
  7. donde una sena YA estaba en tu diccionario, por defecto se suman las dos
     (--empalmes ambas); --empalmes dataset hace que el dataset desplace a las
     tuyas, con un .sql para deshacerlo
  8. regenera plantillas.json en los dos destinos de la app (con respaldo)

Segundo dataset (--dataset iteso): ITESO-MX-100 (Mendeley Data, CC BY 4.0). Los videos se
bajan con tools/descargar_iteso.py (o este script los baja solo) y TODO entra a la base como
'pendiente': no se sabe quien firma cada video (en los nombres de archivo no viene), asi que
no hay expertos, no se aprueba nada, no se exporta plantillas.json y la app no cambia.
Para ver cuantas hay sin tocar la base: python tools/importar_dataset_lsm.py --dataset iteso --seco

Tercer dataset (--dataset wikisigns): Wikisigns LSM (CC BY-SA 4.0), ~2,300 palabras con un video de
YouTube cada una. tools/wikisigns_a_enlaces.py arma la lista y tools/descargar_wikisigns.py baja los videos
a datasets_lsm/wikisigns_lsm/videos/<Palabra>/<id>.mp4 (los privados se saltan). Todo entra 'pendiente',
con el mismo recorte de cuadros quietos que el CICESE, y no se toca plantillas.json.

Dataset incluido (--dataset medico):
  "Mexican Sign Language Glosses (Dynamic Signs)", Navarrete Lopez,
  Sainos-Vizuett y Lopez-Nava (CICESE), Zenodo 10.5281/zenodo.18330565,
  licencia CC BY 4.0 (hay que dar el credito; se escribe en CREDITOS.md).
  121 senas (salud, accidentes, sintomas, cortesia), 12 personas, un video por
  persona y sena, fondo verde, vista frontal. Personas 0 (interprete
  profesional de LSM) y 11 (persona sorda) son expertas; 1 a 10 no firman.

Uso:
    python tools/importar_dataset_lsm.py --probar 6     # primero esto
    python tools/importar_dataset_lsm.py                # luego todo

Opciones utiles:
    --sujetos todos        procesa tambien a las 10 personas no expertas (quedan
                           'pendiente': no entran al paquete hasta que las apruebes)
    --empalmes dataset     el dataset desplaza a tus muestras de las senas que ya
                           tenias (no recomendado, ver arriba). Por defecto: ambas,
                           se suman y no se quita nada
    --deshacer             quita el dataset de lo que usa la app y devuelve tus
                           muestras desplazadas; regenera plantillas.json
    --rehacer              --deshacer y vuelve a importar con el recorte actual
    --carpeta RUTA         usa videos ya descargados y descomprimidos
    --seco                 hace todo menos escribir en la base y exportar
    --sin-exportar         sube a la base pero no toca plantillas.json

Requiere lo mismo que ingest_video.py (DATABASE_URL en .env, los modelos de
MediaPipe) y ~6 GB libres para la descarga y los videos descomprimidos.
"""

import argparse
import csv
import datetime
import glob
import gzip
import hashlib
import json
import math
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import unicodedata
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import sign_norm as sn  # noqa: E402
import dtw  # noqa: E402
from glosa import a_glosa  # noqa: E402

RAIZ = os.path.abspath(os.path.join(HERE, ".."))                 # senas_core
ASSETS = os.path.join(RAIZ, "android", "app", "src", "main", "assets")
DATOS_DEFECTO = os.path.join(RAIZ, "datasets_lsm")
DESTINOS_DEFECTO = [
    r"D:\UNIVOZ_APK\univoz\assets\plantillas.json",      # el que lee la app
    r"D:\UNIVOZ_APK\senas_core\assets\plantillas.json",  # el del paquete
]
RESPALDO_DEFECTO = r"D:\UNIVOZ_APK\_respaldo_antes_de_dataset"

# El reconocedor de la app ya no usa los pesos viejos de tools/dtw.py (ver
# claude/reconocimiento-pocas-muestras.md). Esta copia de dtw.py puede seguir
# con los viejos; aqui se alinean EN MEMORIA para que las pruebas de este
# script midan lo mismo que mide el telefono. No se modifica ningun archivo.
dtw.W_PRES = 0.25
dtw.SHAPE_PENALTY = 0.15
MAX_DISTANCIA_APP = 0.65
MIN_MARGEN_APP = 0.32

# ---------------------------------------------------------------------------
# Datasets conocidos
# ---------------------------------------------------------------------------
DATASETS = {
    "medico": {
        "titulo": "Mexican Sign Language Glosses (Dynamic Signs)",
        "zenodo": "18330565",
        "archivo": "Mexican Sign Language Glosses.7z",
        "md5": "eb2d79005661728a2e94150f4b8d8bdd",   # se vuelve a pedir a Zenodo
        "origen": "zenodo",
        "expertos": {0, 11},
        "categoria": "salud",
        "licencia": "CC BY 4.0",
        "cita": ("Navarrete Lopez, J. A., Sainos-Vizuett, M., & Lopez-Nava, I. H. "
                 "(2026). Mexican Sign Language Glosses (Dynamic Signs) [Data set]. "
                 "Zenodo. https://doi.org/10.5281/zenodo.18330565"),
        # <Glosa>_<Sujeto>.mp4  (tambien acepta Glosa_S3.mp4)
        "patron": r"^(?P<nombre>.+)_[A-Za-z]{0,8}(?P<sujeto>\d+)$",
        "credito": "(CICESE, CC BY 4.0), https://doi.org/10.5281/zenodo.18330565",
    },
    # Alfabeto LSM, letras DINAMICAS (J, K, Ñ, Q, X, Z): CICESE, Zenodo 14689869, vista frontal.
    # 20 personas x 5 repeticiones por letra (~100 tomas por letra); archivos
    # S<persona>-<Letra>-frontal-<repeticion>.mp4 dentro de train/ y test/. Son personas
    # entusiastas de la LSM, no expertas sordas: todo entra 'pendiente' y plantillas.json no cambia.
    # Para aprobar unas pocas por letra:  aprobar_dataset.py --dataset alfabeto --existentes sumar --limite 30
    "alfabeto": {
        "titulo": "Alfabeto LSM, letras dinamicas (CICESE, vista frontal)",
        "zenodo": "14689869",
        "archivo": "MSL-dynamic-signs-frontal-view.7z",
        "archivo_clave": "frontal",              # por si Zenodo lo nombra un poco distinto
        "md5": None,                             # se pide a Zenodo
        "origen": "zenodo",
        "expertos": set(),
        "solo_pendientes": True,
        "categoria": "alfabeto",
        "licencia": "CC BY 4.0",
        "cita": ("Datos del articulo 'A comprehensive dataset of static and dynamic signs for the "
                 "Mexican Sign Language alphabet' (CICESE, Data in Brief 66:112887, 2026). "
                 "Zenodo. https://doi.org/10.5281/zenodo.14689869"),
        # Las personas 2, 19, 20... vienen como 'S2-K-Frontal.1.mp4' (F mayuscula y punto); un
        # 'S19-Z-Perfil.2.mp4' suelto es de la otra vista y se ignora.
        "patron": r"^S(?P<sujeto>\d+)-(?P<nombre>[^-]+)-[Ff]rontal[-.](?P<resto>\d+)$",
        # Los videos reales son recortes cuadrados (900 x 900) de ANTEBRAZO Y MANO, sin hombros
        # (comprobado con --probar el 2026-10-10): se procesan en modo "solo mano".
        "solo_mano": True,
        "aspecto": 1.0,                          # ancho / alto del video
        "credito": "(CICESE, CC BY 4.0), https://doi.org/10.5281/zenodo.14689869",
    },
    # ITESO-MX-100: Mendeley Data g45jkzys4f. Una carpeta por sena, archivos 1.mp4, 2.mp4...
    # Descargar_iteso.py los deja como <Carpeta>__<archivo> en una sola carpeta. No viene
    # quien firma cada video, asi que todo es una sola "persona" (sujeto 0) y todo entra
    # 'pendiente' (solo_pendientes). La clave 'zenodo' guarda aqui el id de Mendeley:
    # se usa para el video_uri ('mendeley:g45jkzys4f/...') y las carpetas de cache.
    "iteso": {
        "titulo": "ITESO-MX-100",
        "zenodo": "g45jkzys4f",
        "origen": "mendeley",
        "descarga": "mendeley",
        "expertos": set(),
        "solo_pendientes": True,
        "sujeto_fijo": 0,
        "anidado": True,
        "categoria": "general",
        "licencia": "CC BY 4.0",
        "cita": ("Martinez Sanchez, V. H. (2026). ITESO-MX-100 [Data set]. "
                 "Mendeley Data, V1. https://doi.org/10.17632/g45jkzys4f.1"),
        "patron": r"^(?P<nombre>.+?)__(?P<resto>.+)$",
        "credito": "(ITESO, CC BY 4.0), https://doi.org/10.17632/g45jkzys4f.1",
    },
    # Wikisigns LSM (https://www.wikisigns.org/list/es/lsm): ~2,300 palabras, un video de
    # YouTube por entrada, de personas distintas (sin dato de quien). Los videos los baja
    # tools/descargar_wikisigns.py como <Palabra>/<id>.mp4. Todo entra 'pendiente'.
    "wikisigns": {
        "titulo": "Wikisigns LSM",
        "zenodo": "lsm",
        "origen": "wikisigns",
        "descarga": "wikisigns",
        "expertos": set(),
        "solo_pendientes": True,
        "sujeto_fijo": 0,
        "anidado": True,
        "categoria": "general",
        "licencia": "CC BY-SA 4.0",
        "cita": ("Wikisigns, Lengua de Senas Mexicana. https://www.wikisigns.org/list/es/lsm "
                 "(CC BY-SA 4.0). Videos de YouTube de sus autores; el registro de cada uno esta en "
                 "datasets_lsm/wikisigns_lsm/entradas.csv"),
        "patron": r"^(?P<nombre>.+?)__(?P<resto>.+)$",
        "credito": "(Wikisigns, CC BY-SA 4.0), https://www.wikisigns.org/list/es/lsm",
    },
    # Glosario Digital de LSM (GDLSM) de INDISCAPACIDAD CDMX (https://lsm.indiscapacidad.cdmx.gob.mx/):
    # 1,050 videos de YouTube en 24 categorias, hechos con organizaciones de personas Sordas.
    # INDISCAPACIDAD es cliente de UNIVOZ y dio autorizacion (Lani, 14-oct-2026). USO: solo
    # APRENDIZAJE (avatar, diccionario, lecciones), NO reconocimiento. La lista (palabra, youtube,
    # categoria) esta en datasets_lsm/indiscapacidad_gdlsm/entradas.csv; los videos los baja
    #     python tools/descargar_wikisigns.py --datos datasets_lsm/indiscapacidad_gdlsm
    # como <Palabra>/<id>.mp4 (las variantes "(1)", "(2)" quedan como dos videos de la misma palabra).
    # Todo entra 'pendiente'; video_uri = 'indiscapacidad:gdlsm/...'.
    "cdmx": {
        "titulo": "Glosario Digital de Lengua de Senas Mexicana (INDISCAPACIDAD CDMX)",
        "zenodo": "gdlsm",
        "origen": "indiscapacidad",
        "descarga": "wikisigns",
        "ayuda_descarga": "    python tools/descargar_wikisigns.py --datos datasets_lsm/indiscapacidad_gdlsm",
        "expertos": set(),
        "solo_pendientes": True,
        "solo_aprendizaje": True,
        "sujeto_fijo": 0,
        "anidado": True,
        "categoria": "general",
        "licencia": "Uso autorizado por INDISCAPACIDAD CDMX (reproduccion requiere su autorizacion)",
        "cita": ("Glosario Digital de Lengua de Senas Mexicana (GDLSM), Instituto de las Personas con "
                 "Discapacidad de la Ciudad de Mexico (INDISCAPACIDAD CDMX) con organizaciones de "
                 "personas Sordas. https://lsm.indiscapacidad.cdmx.gob.mx/"),
        "patron": r"^(?P<nombre>.+?)__(?P<resto>.+)$",
        "credito": "(INDISCAPACIDAD CDMX, uso autorizado), https://lsm.indiscapacidad.cdmx.gob.mx/",
    },
}

# Palabras con su ortografia correcta, para el campo `espanol` de las senas
# NUEVAS (los nombres de archivo suelen venir sin acentos y la app lee ese
# campo en voz alta). Las senas que ya existian conservan el suyo.
_CON_ACENTO = """
si no pregunta duda bien mal duro suave normal frio caliente mejor peor
estresado rapido lento lunes martes miercoles jueves viernes sabado domingo
perro gato camaron pollo abeja cansado confundido ayer ahora hoy manana nunca
siempre diario mama papa esposo esposa hijo hija como cuantos para_que por_que
yo beber cocinar recibir estudiar interpretar ir no_ver dormir pelear trabajar
descansar comer correr caminar ambulancia jarabe virus aborto accidente
hospital doctor enfermera paciente dolor enfermo terapia pastillas inyeccion
contagiar revisar calentura cancer infeccion infarto lesion embarazo sangre
gripa garganta tos debil huesos farmacia emergencia inflamacion analisis
coronavirus cita fractura urgencia orina popo mareo vomito convulsiones gases
diarrea moco sed ojo nariz oreja boca cuello hombro espalda brazo codo muneca
mano panza cintura piernas rodilla tobillo pie adios perdon gracias hola
disculpa por_favor donde que cuando quien medico
"""
_ACENTUADAS = {
    "si": "sí", "frio": "frío", "miercoles": "miércoles", "sabado": "sábado",
    "camaron": "camarón", "manana": "mañana", "mama": "mamá", "papa": "papá",
    "como": "cómo", "cuantos": "cuántos", "para_que": "para qué",
    "por_que": "por qué", "rapido": "rápido", "no_ver": "no ver",
    "inyeccion": "inyección", "cancer": "cáncer", "infeccion": "infección",
    "lesion": "lesión", "debil": "débil", "inflamacion": "inflamación",
    "analisis": "análisis", "popo": "popó", "vomito": "vómito",
    "muneca": "muñeca", "adios": "adiós", "perdon": "perdón",
    "por_favor": "por favor", "donde": "dónde", "que": "qué",
    "cuando": "cuándo", "quien": "quién", "medico": "médico",
}


def espanol_de(nombre):
    """'Inyeccion' -> 'inyección'; 'Dolor de cabeza' -> 'dolor de cabeza'."""
    base = unicodedata.normalize("NFC", nombre).strip().lower()
    plano = a_glosa(base).lower()
    if plano in _ACENTUADAS:
        return _ACENTUADAS[plano]
    return re.sub(r"[_\s]+", " ", base)


# ---------------------------------------------------------------------------
# Mensajes
# ---------------------------------------------------------------------------
_LOG = None


def log(*partes, fin="\n"):
    texto = " ".join(str(p) for p in partes)
    try:
        sys.stdout.write(texto + fin)
    except UnicodeEncodeError:
        sys.stdout.write(texto.encode("ascii", "replace").decode() + fin)
    sys.stdout.flush()
    if _LOG:
        with open(_LOG, "a", encoding="utf-8") as f:
            f.write(texto + fin)


def humano(n):
    for u in ("B", "KB", "MB", "GB"):
        if n < 1024 or u == "GB":
            return f"{n:.1f} {u}" if u != "B" else f"{int(n)} B"
        n /= 1024


def duracion(seg):
    seg = int(seg)
    h, r = divmod(seg, 3600)
    m, s = divmod(r, 60)
    return f"{h}h {m:02d}m" if h else (f"{m}m {s:02d}s" if m else f"{s}s")


# ---------------------------------------------------------------------------
# 1. Descarga (Zenodo) con reanudacion
# ---------------------------------------------------------------------------
def info_zenodo(cfg):
    """Pide a Zenodo el tamano, el MD5 y el link vigentes del archivo."""
    import requests
    rid, nombre = cfg["zenodo"], cfg["archivo"]
    url = f"https://zenodo.org/records/{rid}/files/{requests.utils.quote(nombre)}?download=1"
    info = {"url": url, "md5": cfg.get("md5"), "tam": None}
    try:
        r = requests.get(f"https://zenodo.org/api/records/{rid}", timeout=30)
        r.raise_for_status()
        archivos = r.json().get("files", [])
        elegido = next((f for f in archivos if f.get("key") == nombre), None)
        if elegido is None and cfg.get("archivo_clave"):
            # el nombre guardado puede no ser exacto: se busca el unico archivo que lo contenga
            cand = [f for f in archivos
                    if cfg["archivo_clave"].lower() in (f.get("key") or "").lower()
                    and (f.get("key") or "").lower().endswith((".7z", ".zip"))]
            if len(cand) == 1:
                elegido = cand[0]
                info["url"] = (f"https://zenodo.org/records/{rid}/files/"
                               f"{requests.utils.quote(elegido['key'])}?download=1")
                log(f"  (Zenodo lo llama '{elegido['key']}'; uso ese)")
            else:
                log("  (no encontre el archivo en Zenodo; archivos que ve la API: "
                    + ", ".join(f.get("key", "?") for f in archivos) + ")")
        if elegido is not None:
            info["tam"] = elegido.get("size")
            cs = elegido.get("checksum") or ""
            if cs.startswith("md5:"):
                info["md5"] = cs[4:]
    except Exception as e:  # sin API se sigue con los datos guardados
        log(f"  (no pude consultar la API de Zenodo: {e}; sigo con el link directo)")
    return info


def md5_de(ruta):
    h = hashlib.md5()
    with open(ruta, "rb") as f:
        for bloque in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(bloque)
    return h.hexdigest()


def descargar(cfg, carpeta):
    import requests
    os.makedirs(carpeta, exist_ok=True)
    destino = os.path.join(carpeta, cfg["archivo"])
    info = info_zenodo(cfg)

    if os.path.exists(destino):
        if info["tam"] and os.path.getsize(destino) != info["tam"]:
            log("  el archivo ya descargado no mide lo que debe; lo bajo de nuevo")
            os.remove(destino)
        else:
            log(f"  ya estaba descargado: {destino}")
            verificar_md5(destino, info)
            return destino, info

    parcial = destino + ".part"
    if os.path.exists(destino + ".md5ok"):        # marca de una descarga anterior
        os.remove(destino + ".md5ok")
    for intento in range(1, 31):
        ya = os.path.getsize(parcial) if os.path.exists(parcial) else 0
        if info["tam"] and ya == info["tam"]:
            break
        headers = {"Range": f"bytes={ya}-"} if ya else {}
        try:
            with requests.get(info["url"], stream=True, headers=headers, timeout=60) as r:
                if r.status_code == 416:       # ya estaba completo
                    break
                if r.status_code not in (200, 206):
                    raise RuntimeError(f"Zenodo respondio {r.status_code}")
                if ya and r.status_code == 200:  # el servidor ignoro el rango
                    ya = 0
                total = ya + int(r.headers.get("Content-Length") or 0)
                if not info["tam"] and total:
                    info["tam"] = total
                modo = "ab" if ya else "wb"
                t0, bytes0, ultimo = time.monotonic(), ya, 0.0
                with open(parcial, modo) as f:
                    for bloque in r.iter_content(chunk_size=1024 * 1024):
                        f.write(bloque)
                        ya += len(bloque)
                        if time.monotonic() - ultimo > 2:
                            ultimo = time.monotonic()
                            vel = (ya - bytes0) / max(1e-6, ultimo - t0)
                            falta = (total - ya) / vel if vel > 0 and total else 0
                            sys.stdout.write(
                                f"\r  descargando {humano(ya)} / {humano(total)}"
                                f"  ({humano(vel)}/s, faltan ~{duracion(falta)})   ")
                            sys.stdout.flush()
            sys.stdout.write("\n")
            if not info["tam"] or os.path.getsize(parcial) >= info["tam"]:
                break
        except Exception as e:
            sys.stdout.write("\n")
            log(f"  la descarga se corto ({e}); reintento {intento}/30 en 5 s ...")
            time.sleep(5)
    else:
        raise SystemExit("no pude terminar la descarga. Vuelve a correr el mismo "
                         "comando: continua donde se quedo.")

    os.replace(parcial, destino)
    verificar_md5(destino, info)
    return destino, info


def verificar_md5(destino, info):
    marca = destino + ".md5ok"
    if not info.get("md5") or os.path.exists(marca):
        return
    log("  verificando MD5 ...")
    real = md5_de(destino)
    if real.lower() != info["md5"].lower():
        os.remove(destino)
        raise SystemExit(
            f"el MD5 no coincide (esperado {info['md5']}, obtenido {real}): la descarga "
            "llego danada. Ya borre el archivo; vuelve a correr el mismo comando.")
    with open(marca, "w") as f:
        f.write(real)
    log("  MD5 correcto")


# ---------------------------------------------------------------------------
# 2. Descompresion (.7z): py7zr, 7-Zip o tar de Windows
# ---------------------------------------------------------------------------
def descomprimir(archivo, destino):
    marca = os.path.join(destino, ".extraido")
    if os.path.exists(marca):
        log(f"  ya estaba descomprimido en {destino}")
        return
    os.makedirs(destino, exist_ok=True)

    def listo():
        with open(marca, "w") as f:
            f.write(datetime.datetime.now().isoformat())
        log("  descomprimido")

    try:
        import py7zr
        log("  descomprimiendo con py7zr (tarda unos minutos) ...")
        with py7zr.SevenZipFile(archivo) as z:
            z.extractall(destino)
        return listo()
    except ImportError:
        pass
    except Exception as e:
        log(f"  py7zr fallo ({e}); pruebo con otro descompresor")

    candidatos = [shutil.which(x) for x in ("7z", "7za", "7zz")]
    candidatos += [r"C:\Program Files\7-Zip\7z.exe", r"C:\Program Files (x86)\7-Zip\7z.exe"]
    for exe in [c for c in candidatos if c and os.path.exists(c)]:
        log(f"  descomprimiendo con {exe} ...")
        if subprocess.run([exe, "x", "-y", f"-o{destino}", archivo]).returncode == 0:
            return listo()

    tar = shutil.which("tar")
    if tar:
        log("  descomprimiendo con tar de Windows ...")
        if subprocess.run([tar, "-xf", archivo, "-C", destino]).returncode == 0:
            return listo()

    log("  probando instalar py7zr ...")
    if subprocess.run([sys.executable, "-m", "pip", "install", "py7zr"]).returncode == 0:
        try:
            import py7zr  # noqa: F811
            with py7zr.SevenZipFile(archivo) as z:
                z.extractall(destino)
            return listo()
        except Exception as e:
            log(f"  py7zr no pudo: {e}")

    raise SystemExit(
        "no encontre como descomprimir el .7z. Instala 7-Zip (en PowerShell:\n"
        "    winget install 7zip.7zip\n"
        f"), descomprime {archivo}\n"
        f"en una carpeta y vuelve a correr con:  --carpeta <esa carpeta>")


# ---------------------------------------------------------------------------
# 3. Lista de videos
# ---------------------------------------------------------------------------
def listar_videos(carpeta, cfg, sujetos):
    rx = re.compile(cfg["patron"])
    out, ignorados = [], []
    for raiz, _dirs, archivos in os.walk(carpeta):
        for a in archivos:
            if not a.lower().endswith((".mp4", ".mov", ".avi", ".mkv")):
                continue
            a_plano = a
            if a.startswith("._") or "__MACOSX" in raiz:
                continue                      # basura de zips hechos en Mac
            stem = unicodedata.normalize("NFC", os.path.splitext(a)[0])
            m = rx.match(stem)
            if m:
                nombre = m.group("nombre")
            elif cfg.get("anidado") and os.path.normpath(raiz) != os.path.normpath(carpeta):
                # Tal como lo baja Mendeley ("Download All"): <Seña>/1.mp4, <Seña>/2.mp4...
                # El nombre plano <Seña>__<archivo> es el mismo que deja descargar_iteso.py,
                # asi la muestra (video_uri) y el cache son iguales vengan de donde vengan.
                nombre = unicodedata.normalize("NFC", os.path.basename(os.path.normpath(raiz)))
                a_plano = f"{nombre}__{a}"
            else:
                ignorados.append(a)
                continue
            suj = int(m.group("sujeto")) if "sujeto" in rx.groupindex else cfg.get("sujeto_fijo", 0)
            if sujetos is not None and suj not in sujetos:
                continue
            out.append({
                "ruta": os.path.join(raiz, a), "archivo": a_plano if (not m and cfg.get("anidado")) else a,
                "nombre": nombre,
                "gloss": a_glosa(nombre), "sujeto": suj,
                "experto": suj in cfg["expertos"],
            })
    out.sort(key=lambda v: (v["gloss"], v["sujeto"]))
    return out, ignorados


# ---------------------------------------------------------------------------
# 4. Landmarks -> muestra normalizada
# ---------------------------------------------------------------------------
# Version del recorte. Va en la firma del cache y en el video_uri de las muestras:
# si cambia, todo se recalcula y entra como muestra nueva (las viejas quedan).
#   v1: el calculo de velocidad estaba al reves para videos de mas de 30 fps y la
#       persona 11 (60 fps, ~6 s con una pausa larga al final) casi nunca se recortaba.
#   v2: se baja a ~30 fps antes de todo y el umbral se adapta al dataset.
TRIM_VERSION = 2
FPS_APP = 30.0                # la app procesa ~30 cuadros por segundo
UMBRAL_MOVIMIENTO = 0.006     # por 1/30 s, sobre la senal suavizada. La app usa 0.015 sobre cuadros
                              # sueltos; las personas expertas hacen gestos mas suaves y con 0.015
                              # la persona 11 casi nunca lo pasaba.
SUAVIZADO = 5                 # cuadros (promedio movil)
ONSET_MIN = 3                 # cuadros seguidos sobre el umbral para dar por empezada la sena
MARGEN_INI = 3                # cuadros antes del primer movimiento
FRAMES_QUIETOS = 20           # cuadros quietos que cierran la sena (igual que DetectorAutomatico, a 30 fps)
MIN_FRAMES = 8


def a_30fps(raw, fps):
    """Videos de 60 fps -> uno de cada dos cuadros, como los ve la app. Devuelve
    (cuadros, fps efectivo)."""
    paso = max(1, int(round(fps / FPS_APP)))
    return raw[::paso], fps / paso


def _mov_manos(a, b):
    """Igual que _calcularMovimiento del detector de la app: cambio medio por
    coordenada (x, y) de los landmarks de cada mano entre dos frames."""
    suma, n = 0.0, 0
    for k in (2, 3):                        # left, right
        ma, mb = a[k], b[k]
        if ma is None or mb is None:
            continue
        for pa, pb in zip(ma, mb):
            suma += abs(pb[0] - pa[0]) + abs(pb[1] - pa[1])
            n += 2
    return suma / n if n else 0.0


def _perfil_movimiento(raw, fps):
    """Movimiento de las manos por cuadro, en unidades "por 1/30 s" (asi un video
    de 25, 30 o 60 fps se mide igual) y suavizado."""
    esc = fps / FPS_APP                      # desplazamiento por 1/30 s = por cuadro * fps/30
    mov = [0.0]
    for i in range(1, len(raw)):
        tiene = raw[i][2] is not None or raw[i][3] is not None
        mov.append(_mov_manos(raw[i - 1], raw[i]) * esc if tiene else 0.0)
    k = SUAVIZADO
    if len(mov) < k:
        return mov
    mitad = k // 2
    out = []
    for i in range(len(mov)):
        a, b = max(0, i - mitad), min(len(mov), i + mitad + 1)
        out.append(sum(mov[a:b]) / (b - a))
    return out


def recortar_por_movimiento(raw, fps):
    """Lo que la app graba en vivo es desde que las manos se mueven hasta que
    llevan ~0.7 s quietas. Aqui se hace lo mismo con el video: empieza en el
    primer movimiento sostenido y termina en la primera racha de FRAMES_QUIETOS
    cuadros quietos (la pausa larga que algunas personas dejan al final se
    descarta). Si el clip se acaba antes de completar esa cola, se repite el
    ultimo cuadro. `raw` ya debe venir a ~30 fps (ver a_30fps).
    Devuelve (frames, (ini, fin), cola_repetida)."""
    mov = _perfil_movimiento(raw, fps)
    q = max(2, int(round(FRAMES_QUIETOS * fps / FPS_APP)))
    act = [m > UMBRAL_MOVIMIENTO for m in mov]
    ini = None
    for i in range(len(act) - ONSET_MIN + 1):
        if all(act[i:i + ONSET_MIN]):
            ini = max(0, i - MARGEN_INI)
            break
    if ini is None:
        return raw, (0, len(raw) - 1), 0
    quietos, fin = 0, None
    for i in range(ini + 1, len(raw)):
        if act[i]:
            quietos = 0
        else:
            quietos += 1
            if quietos >= q:
                fin = i
                break
    relleno = 0
    if fin is None:
        fin = len(raw) - 1
        relleno = max(0, q - quietos)
    seg = raw[ini:fin + 1] + [raw[-1]] * relleno
    if len(seg) < MIN_FRAMES:
        return raw, (0, len(raw) - 1), 0
    return seg, (ini, fin), relleno


# ---------------------------------------------------------------------------
# Modo "solo mano": videos que son un recorte de antebrazo y mano, sin hombros (p. ej. las
# letras dinamicas del CICESE). sign_norm descarta todo cuadro sin hombros, asi que aqui se le
# da un esqueleto NEUTRO (persona de frente, hombros horizontales) y la muneca se mueve sobre
# el esqueleto segun lo que se movio la mano en el video. Es el mismo esqueleto que usa
# importar_alfabeto_estatico.py.
#   - FORMA de la mano: la del detector de manos, igual que siempre (se guarda como si el
#     recorte estuviera dentro de un cuadro 16:9 a la misma escala: x y z por aspecto / (16/9);
#     curar_plantillas.py la devuelve a su forma real).
#   - UBICACION: desplazamiento de la muneca en el video, medido en tamanos de mano (muneca ->
#     nudillo medio) y pasado a metros con HAND_M. Solo cuenta el movimiento, no donde esta la
#     mano en el recorte: la app centra la ubicacion de cada secuencia antes de comparar.
#   - CUERPO: constante. El reconocimiento de la app no usa el cuerpo (W_BODY = 0).
# Estas muestras NO sirven para que el avatar se vea bien en el espacio.
# ---------------------------------------------------------------------------
HAND_M = 0.095                  # muneca -> nudillo medio en metros (0.25 de 0.38 m de hombros, como
                                # el respaldo de sign_norm)
SOLO_MANO_VERSION = 1


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


def a_solo_mano(raw, aspecto=1.0, convencion_16_9=True):
    """raw (pose, pose_mundo, left, right) por cuadro de un video SIN hombros -> raw con el esqueleto
    neutro y una sola mano. Los cuadros sin mano quedan (None, None, None, None): normalize_frame
    los da por no validos y fill_gaps los rellena con el ultimo bueno."""
    izq = sum(1 for fr in raw if fr[2] is not None)
    der = sum(1 for fr in raw if fr[3] is not None)
    lado = "izq" if izq >= der else "der"            # por votacion de toda la toma
    manos = []
    for (_p, _pm, l, r) in raw:
        propia, otra = (l, r) if lado == "izq" else (r, l)
        manos.append(propia if propia is not None else otra)

    escalas = []
    for h in manos:
        if h is not None:
            esc = math.hypot((h[9][0] - h[0][0]) * aspecto, h[9][1] - h[0][1])
            if esc > 1e-4:
                escalas.append(esc)
    esc_med = statistics.median(escalas) if escalas else None
    k = (aspecto / (16.0 / 9.0)) if convencion_16_9 else 1.0
    idx = 15 if lado == "izq" else 16
    ref = None
    out = []
    for h in manos:
        if h is None or esc_med is None:
            out.append((None, None, None, None))
            continue
        w = (h[0][0] * aspecto, h[0][1])             # en unidades de alto de imagen: x e y comparables
        if ref is None:
            ref = w
        mundo = [list(q) for q in MUNDO_NEUTRO]
        mundo[idx][0] += (w[0] - ref[0]) / esc_med * HAND_M
        mundo[idx][1] += (w[1] - ref[1]) / esc_med * HAND_M
        hk = [[q[0] * k, q[1], q[2] * k] for q in h]
        out.append((POSE_NEUTRA, mundo, hk if lado == "izq" else None, hk if lado == "der" else None))
    return out


def muestra_desde_raw(raw, fps, recortar=True, espejo=False, solo_mano=False, aspecto=1.0):
    """raw: lista (pose, pose_mundo, left, right). Devuelve dict o None."""
    if solo_mano:
        raw = a_solo_mano(raw, aspecto)
    if espejo:
        raw = [(p, pm, r, l) for (p, pm, l, r) in raw]
    total = len(raw)
    raw, fps = a_30fps(raw, fps)
    recorte = (0, len(raw) - 1)
    relleno = 0
    if recortar:
        raw, recorte, relleno = recortar_por_movimiento(raw, fps)

    norm = [sn.normalize_frame(p, pm, l, r) for (p, pm, l, r) in raw]
    validos = [f for f in norm if f is not None]
    vis = []
    for (p, _pm, _l, _r) in raw:
        if p is not None and len(p) > max(sn.L_SHOULDER, sn.R_SHOULDER):
            ls, rs = p[sn.L_SHOULDER], p[sn.R_SHOULDER]
            if len(ls) > 3 and len(rs) > 3:
                vis.append(min(ls[3], rs[3]))
    res = {
        "n_frames_video": total, "n_frames": len(raw), "fps": fps,
        "recorte": list(recorte), "cola_repetida": relleno, "validos": len(validos),
        "frac_validos": len(validos) / max(1, len(raw)),
        "visibilidad_min": min(vis) if vis else None,
        "frac_con_mano": 0.0, "frac_dos_manos": 0.0, "seq": None,
    }
    if solo_mano:
        res["solo_mano"] = True        # 'frac_validos' = cuadros con mano; no hay hombros que ver
    if validos:
        con = sum(1 for f in validos if f[sn.OFF_PRES_L] >= 0.5 or f[sn.OFF_PRES_R] >= 0.5)
        dos = sum(1 for f in validos if f[sn.OFF_PRES_L] >= 0.5 and f[sn.OFF_PRES_R] >= 0.5)
        res["frac_con_mano"] = con / len(validos)
        res["frac_dos_manos"] = dos / len(validos)
        filled = sn.fill_gaps(norm)
        seq = sn.resample(filled, sn.T_FRAMES)
        res["seq"] = [[round(float(x), 5) for x in fr] for fr in seq]
    return res


def veredicto(m):
    """None si sirve; si no, el motivo."""
    if m["seq"] is None:
        return "ningun frame con mano detectada" if m.get("solo_mano") else "ningun frame con hombros visibles"
    if m["n_frames"] < MIN_FRAMES:
        return f"muy corto ({m['n_frames']} frames)"
    if m["frac_validos"] < 0.6:
        if m.get("solo_mano"):
            return f"mano detectada solo en {m['frac_validos']:.0%} de los frames"
        return f"hombros visibles solo en {m['frac_validos']:.0%} de los frames"
    if m["frac_con_mano"] < 0.3:
        return f"manos detectadas solo en {m['frac_con_mano']:.0%} de los frames"
    return None


def _redondear_raw(raw):
    """5 decimales: sobra para MediaPipe y hace el cache 3 veces mas chico."""
    def r(lista):
        return None if lista is None else [[round(float(x), 5) for x in p] for p in lista]
    return [(r(p), r(pm), r(l), r(rr)) for (p, pm, l, rr) in raw]


def _ruta_raw(v):
    return v["cache"][:-len(".json")] + ".raw.json.gz"


def _guardar_raw(v, raw, fps, n):
    with gzip.open(_ruta_raw(v), "wt", encoding="utf-8") as f:
        json.dump({"fps": fps, "n": n, "raw": raw}, f)


def _cargar_raw(v):
    try:
        with gzip.open(_ruta_raw(v), "rt", encoding="utf-8") as f:
            c = json.load(f)
        raw = [tuple(fr) for fr in c["raw"]]
        return raw, c["fps"], c["n"]
    except Exception:
        return None


def procesar_videos(videos, args, carpeta_cache, cfg=None):
    """Landmarks de cada video. Guarda un JSON por video (y los landmarks crudos
    comprimidos): si se interrumpe, al volver a correr sigue donde se quedo, y si
    cambia el recorte se recalcula sin volver a correr MediaPipe."""
    os.makedirs(carpeta_cache, exist_ok=True)
    firma = {"recortar": not args.sin_recorte, "espejo": args.espejo, "norm": sn.NORM_VERSION,
             "trim": TRIM_VERSION}
    solo_mano = bool(cfg and cfg.get("solo_mano"))
    aspecto = float((cfg or {}).get("aspecto", 1.0))
    if solo_mano:                    # solo en este modo: los caches de los otros datasets no cambian
        firma["solo_mano"] = SOLO_MANO_VERSION
        firma["aspecto"] = aspecto

    pendientes = []
    for v in videos:
        ruta_c = os.path.join(carpeta_cache, v["archivo"] + ".json")
        v["cache"] = ruta_c
        ok = False
        if os.path.exists(ruta_c):
            try:
                with open(ruta_c, encoding="utf-8") as f:
                    c = json.load(f)
                ok = c.get("firma") == firma
            except Exception:
                ok = False
        if not ok:
            pendientes.append(v)

    if pendientes:
        extractor = None
        tmp = tempfile.mkdtemp(prefix="lsm_")       # OpenCV en Windows no abre
        t0 = time.monotonic()                       # rutas con acentos
        try:
            for i, v in enumerate(pendientes, 1):
                ini = time.monotonic()
                try:
                    cargado = _cargar_raw(v)
                    if cargado is None:
                        if extractor is None:
                            for p in (args.pose_model, args.hand_model):
                                if not os.path.exists(p):
                                    raise SystemExit(
                                        f"no encuentro el modelo de MediaPipe: {p}\n"
                                        "Pasa --pose-model / --hand-model con la ruta correcta.")
                            from extraer_landmarks import ExtractorLandmarks
                            extractor = ExtractorLandmarks(args.pose_model, args.hand_model)
                        copia = os.path.join(tmp, "v" + os.path.splitext(v["archivo"])[1].lower())
                        shutil.copyfile(v["ruta"], copia)
                        raw, fps, n = extractor.extraer(copia)
                        if n == 0:
                            raise ValueError("video sin frames legibles")
                        raw = _redondear_raw(raw)
                        _guardar_raw(v, raw, fps, n)
                    else:
                        raw, fps, n = cargado
                    m = muestra_desde_raw(raw, fps, recortar=not args.sin_recorte,
                                          espejo=args.espejo, solo_mano=solo_mano, aspecto=aspecto)
                except SystemExit:
                    raise
                except Exception as e:
                    m = {"error": str(e), "seq": None, "n_frames": 0, "n_frames_video": 0,
                         "fps": 0, "validos": 0, "frac_validos": 0.0, "frac_con_mano": 0.0,
                         "frac_dos_manos": 0.0, "visibilidad_min": None, "recorte": [0, 0],
                         "cola_repetida": 0}
                m.update({"archivo": v["archivo"], "gloss": v["gloss"], "nombre": v["nombre"],
                          "sujeto": v["sujeto"], "firma": firma})
                with open(v["cache"], "w", encoding="utf-8") as f:
                    json.dump(m, f)
                hecho = time.monotonic() - t0
                eta = hecho / i * (len(pendientes) - i)
                motivo = veredicto(m) if not m.get("error") else "ERROR: " + m["error"]
                log(f"  [{i:>4}/{len(pendientes)}] {v['archivo']:<38} "
                    f"{m['n_frames_video']:>4} fr -> {m['n_frames']:>4}  "
                    f"{'mano' if m.get('solo_mano') else 'hombros'} {m['frac_validos']:>4.0%}  "
                    f"manos {m['frac_con_mano']:>4.0%}  "
                    f"{time.monotonic() - ini:4.1f}s  "
                    + (f"DESCARTADO: {motivo}" if motivo else "ok")
                    + f"   (faltan ~{duracion(eta)})")
        finally:
            if extractor is not None:
                extractor.cerrar()
            shutil.rmtree(tmp, ignore_errors=True)

    muestras = []
    for v in videos:
        with open(v["cache"], encoding="utf-8") as f:
            m = json.load(f)
        m["experto"] = v["experto"]
        m["motivo"] = "ERROR: " + m["error"] if m.get("error") else veredicto(m)
        muestras.append(m)
    return muestras


# ---------------------------------------------------------------------------
# 5. Lo que ya tienes
# ---------------------------------------------------------------------------
def cargar_paquete(rutas):
    """(gloss, espanol, seq) de la primera plantillas.json que exista."""
    for r in rutas:
        if r and os.path.exists(r):
            try:
                with open(r, encoding="utf-8") as f:
                    d = json.load(f)
                if d.get("frame_dim") == sn.FRAME_DIM:
                    return r, [(t["gloss"], t.get("espanol", ""), t["seq"])
                               for t in d["plantillas"]]
            except Exception:
                continue
    return None, []


class Referencias:
    """Para decidir si una sena tuya "es la misma" que la del dataset.

    Se compara SOLO contra el dataset: la muestra tuya se parece mas a la
    sena G del dataset que a cualquiera de sus otras senas? Asi el desfase
    entre tus videos y los del dataset (camara, fondo, persona) afecta a
    todas las comparaciones por igual y no decide el resultado. No se usa una
    distancia fija: con una sola muestra por sena dos personas haciendo la
    MISMA sena suelen quedar a mas de 0.65. Las plantillas se espejan, como
    hace la app."""

    def __init__(self, buenas_expertas):
        mk = dtw.Template
        self.clf = dtw.DtwClassifier(prefilter=80)
        for m in buenas_expertas:
            self.clf.templates.append(mk(m["gloss"], m["gloss"], m["seq"]))
            self.clf.templates.append(mk(m["gloss"], m["gloss"], sn.mirror_sequence(m["seq"])))

    def mejor(self, seq):
        """(glosa del dataset mas cercana, distancia)."""
        r = self.clf.rank(seq)
        return (r[0][1].gloss, r[0][0]) if r else (None, float("inf"))


# ---------------------------------------------------------------------------
# 6. Prueba entre expertos: uno firma, el otro reconoce
# ---------------------------------------------------------------------------
def prueba_entre_expertos(buenas, propias, expertos):
    por_sujeto = {}
    for m in buenas:
        if m["sujeto"] in expertos:
            por_sujeto.setdefault(m["sujeto"], []).append(m)
    if len(por_sujeto) < 2:
        log("  (hace falta mas de una persona experta con tomas buenas; salto la prueba)")
        return None
    resultados = {}
    sujetos = sorted(por_sujeto)
    for consulta in sujetos:
        clf = dtw.DtwClassifier(max_distance=MAX_DISTANCIA_APP, min_margin=MIN_MARGEN_APP,
                                prefilter=80)
        for s in sujetos:
            if s == consulta:
                continue
            for m in por_sujeto[s]:
                clf.add(m["gloss"], m["gloss"], m["seq"])
                clf.add(m["gloss"], m["gloss"], sn.mirror_sequence(m["seq"]))
        glosas_ds = {m["gloss"] for s in sujetos if s != consulta for m in por_sujeto[s]}
        # tus plantillas ya existentes entran como distractoras
        for g, _e, seq in propias:
            if g in glosas_ds:
                continue                      # esa sena la representa el dataset
            clf.add(g, g, seq)
            clf.add(g, g, sn.mirror_sequence(seq))
        acierta = acepta = usable = 0
        confusiones = {}
        d_misma = []
        for m in por_sujeto[consulta]:
            if m["gloss"] not in glosas_ds:
                continue                      # el otro experto no la tiene buena
            usable += 1
            ds = [dtw.dtw_distance(m["seq"], t.seq, dtw.BAND) for t in clf.templates
                  if t.gloss == m["gloss"]]
            if ds:
                d_misma.append(min(ds))
            p = clf.classify(m["seq"])
            if p.gloss == m["gloss"]:
                acierta += 1
                if p.aceptada:
                    acepta += 1
            else:
                confusiones[(m["gloss"], p.gloss)] = distancia_o(p)
        resultados[consulta] = {"consultas": usable, "acierta": acierta, "acepta": acepta,
                                "confusiones": confusiones, "d_misma": d_misma}
        if usable:
            log(f"  firma la persona {consulta}, reconoce con la otra: "
                f"{acierta}/{usable} correctas ({acierta / usable:.0%}), "
                f"{acepta} aceptadas por los umbrales de la app ({acepta / usable:.0%})")
    return resultados


def veredicto_prueba(resultados):
    """(acierto entre expertas, distancia mediana de la misma sena, texto)."""
    if not resultados:
        return None, None, "no se pudo hacer la prueba entre expertas"
    tot = sum(r["consultas"] for r in resultados.values())
    ok = sum(r["acierta"] for r in resultados.values())
    ds = sorted(d for r in resultados.values() for d in r["d_misma"])
    if not tot:
        return None, None, "no hubo senas buenas en las dos expertas para comparar"
    acierto = ok / tot
    dmed = ds[len(ds) // 2] if ds else None
    if acierto >= 0.5:
        txt = (f"Las dos expertas se reconocen entre si ({acierto:.0%}): las plantillas del dataset "
               "sirven para reconocer.")
    else:
        txt = (f"OJO: las dos expertas casi NO se reconocen entre si ({acierto:.0%} de acierto"
               + (f"; la misma sena queda a {dmed:.2f} de distancia y la app acepta hasta "
                  f"{MAX_DISTANCIA_APP}" if dmed is not None else "")
               + "). Con una toma por persona, estas plantillas casi nunca serian aceptadas por "
                 "la camara. Si sirven para que el avatar ENSENE la sena (modo Aprender) y no "
                 "estorban a tus senas, pero no cuentes con ellas para reconocer.")
    return acierto, dmed, txt


def distancia_o(p):
    return round(p.distance, 3) if p.distance != float("inf") else None


# ---------------------------------------------------------------------------
# 7. Base de datos
# ---------------------------------------------------------------------------
def signer_uuid(nombre):
    # mismo calculo que ingest_video.py / importar_muestras.py
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, "univoz-signer:" + nombre.strip().lower()))


def a_bytes(blob):
    return bytes(blob)


def importar_a_base(buenas, cfg, args, carpeta_datos):
    from dotenv import load_dotenv
    load_dotenv()
    import db

    prefijo = f"{cfg['origen']}:{cfg['zenodo']}/"
    resumen = {"nuevas": [], "empalmes": [], "muestras": 0, "ya_estaban": 0,
               "pendientes": 0, "rechazadas_propias": 0}
    restaurar = []

    por_glosa = {}
    for m in buenas:
        por_glosa.setdefault(m["gloss"], []).append(m)
    refs = Referencias([m for m in buenas if m["experto"]])

    conn = db.conectar()
    try:
        cur = conn.cursor()
        # Una sola consulta para todo lo que ya hay (con una base remota, preguntar de a
        # una muestra son miles de viajes y se ve como si se hubiera trabado).
        cur.execute("SELECT gloss, id FROM signs")
        ids_signs = {r[0]: r[1] for r in cur.fetchall()}
        cur.execute("SELECT video_uri FROM sign_samples WHERE video_uri LIKE %s", (prefijo + "%",))
        uris_ya = {r[0] for r in cur.fetchall()}
        total_glosas = len(por_glosa)
        t0 = time.time()
        print(f"  {total_glosas} senas, {len(buenas)} tomas; ya hay {len(uris_ya)} de este dataset en la base",
              flush=True)
        for n_glosa, (gloss, ms) in enumerate(sorted(por_glosa.items()), start=1):
            sign_id_previo = ids_signs.get(gloss)
            existia = sign_id_previo is not None
            fila = (sign_id_previo,) if existia else None
            esp = espanol_de(ms[0]["nombre"])
            manos = 2 if statistics.mean(m["frac_dos_manos"] for m in ms) >= 0.4 else 1
            if existia:
                sign_id = fila[0]
            elif args.seco:
                sign_id = None
            else:
                sign_id = db.upsert_sign(conn, gloss, esp, categoria=cfg["categoria"],
                                         manos=manos)
                ids_signs[gloss] = sign_id
            if not existia:
                resumen["nuevas"].append((gloss, esp))

            nuevas_aprobadas = []
            for m in ms:
                uri = prefijo + m["archivo"] + f"#t{TRIM_VERSION}"   # version del recorte
                if sign_id is not None:
                    if uri in uris_ya:
                        resumen["ya_estaban"] += 1
                        if args.rehacer and not args.seco:
                            # --rehacer acaba de dejarla 'rechazada' (o ya lo estaba): se reactiva
                            cur.execute(
                                "UPDATE sign_samples SET estado = %s "
                                "WHERE video_uri = %s AND estado = 'rechazada'",
                                ("aprobada" if (m["experto"] and not args.como_pendientes)
                                 else "pendiente", uri))
                        if m["experto"] and not args.como_pendientes:
                            nuevas_aprobadas.append(m)
                        continue
                aprobar = m["experto"] and not args.como_pendientes
                if aprobar:
                    nuevas_aprobadas.append(m)
                else:
                    resumen["pendientes"] += 1
                resumen["muestras"] += 1
                if args.seco:
                    continue
                sid = db.insertar_muestra(
                    conn, sign_id, origen="video", video_uri=uri, fps=m["fps"],
                    duracion_ms=int(m["n_frames"] / m["fps"] * 1000) if m["fps"] else None,
                    n_frames_orig=m["n_frames_video"],
                    frames_invalidos=m["n_frames"] - m["validos"],
                    visibilidad_min=m["visibilidad_min"], quality_score=m["frac_validos"],
                    signer_id=signer_uuid(f"{cfg['origen']}-{cfg['zenodo']}-sujeto-{m['sujeto']}"),
                    mano_dominante=None, estado="aprobada" if aprobar else "pendiente")
                db.insertar_landmarks(conn, sid, sn.NORM_VERSION, sn.T_FRAMES, sn.FRAME_DIM,
                                      sn.pack_f16(m["seq"]))
                uris_ya.add(uri)

            # --- empalme: la sena ya existia con muestras propias -----------
            if existia and nuevas_aprobadas:
                cur.execute(
                    """SELECT ss.id, sl.data
                       FROM sign_samples ss JOIN sample_landmarks sl ON sl.sample_id = ss.id
                       WHERE ss.sign_id = %s AND ss.estado = 'aprobada'
                         AND ss.origen <> 'espejo' AND sl.norm_version = %s
                         AND (ss.video_uri IS NULL OR ss.video_uri NOT LIKE %s)""",
                    (sign_id, sn.NORM_VERSION, cfg["origen"] + ":%"))
                propias = [(r[0], sn.unpack_f16(a_bytes(r[1]))) for r in cur.fetchall()]
                if propias:
                    vistas = [refs.mejor(seq) for _id, seq in propias]
                    aciertos = sum(1 for g, _d in vistas if g == gloss)
                    de_acuerdo = aciertos / len(propias) >= args.acuerdo
                    decision = "ambas"
                    if (args.empalmes == "dataset-siempre"
                            or (args.empalmes == "dataset" and de_acuerdo)):
                        decision = "dataset"
                        ids = [i for i, _s in propias]
                        restaurar.extend(ids)
                        if not args.seco:
                            cur.execute(
                                "UPDATE sign_samples SET estado = 'rechazada' "
                                "WHERE id = ANY(%s::uuid[]) OR derivada_de = ANY(%s::uuid[])",
                                (ids, ids))
                        resumen["rechazadas_propias"] += len(ids)
                    resumen["empalmes"].append({
                        "gloss": gloss, "propias": len(propias),
                        "dataset": len(nuevas_aprobadas), "aciertos": aciertos,
                        "decision": decision, "de_acuerdo": de_acuerdo,
                        "confundida_con": sorted({g for g, _d in vistas if g != gloss})})
            # Se guarda por tandas de 25 senas: si se corta, lo ultimo sin guardar se descarta
            # entero y al volver a correr sigue desde ahi (no quedan muestras a medias).
            if not args.seco and n_glosa % 25 == 0:
                conn.commit()
            if n_glosa % 25 == 0 or n_glosa == total_glosas:
                dt = time.time() - t0
                falta = dt / n_glosa * (total_glosas - n_glosa)
                print(f"  senas {n_glosa}/{total_glosas}  muestras nuevas {resumen['muestras']}"
                      f"  ({int(dt // 60)}:{int(dt % 60):02d}; faltan ~{int(falta // 60)}:{int(falta % 60):02d})",
                      flush=True)
        if not args.seco:
            conn.commit()
        else:
            conn.rollback()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

    if restaurar and not args.seco:
        ruta = os.path.join(carpeta_datos, "restaurar_propias_%s.sql"
                            % datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))
        with open(ruta, "w", encoding="utf-8") as f:
            f.write("-- Devuelve a 'aprobada' las muestras tuyas que el dataset desplazo.\n"
                    "-- Correlo en el SQL Editor de Supabase y luego exportar_paquete.py.\n")
            lista = ",\n  ".join("'%s'" % i for i in restaurar)
            f.write("UPDATE sign_samples SET estado = 'aprobada'\n"
                    "WHERE id IN (\n  " + lista + "\n)\n"
                    "   OR derivada_de IN (\n  " + lista + "\n);\n")
        resumen["archivo_restaurar"] = ruta
    return resumen


UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


def deshacer(cfg, carpeta_datos, seco=False):
    """Quita el dataset de lo que usa la app (no borra nada: 'rechazada') y devuelve
    las muestras tuyas que habia desplazado."""
    from dotenv import load_dotenv
    load_dotenv()
    import db

    prefijo = f"{cfg['origen']}:{cfg['zenodo']}/%"
    archivos = [a for a in sorted(glob.glob(os.path.join(carpeta_datos, "restaurar_propias_*.sql")))
                if not a.endswith("_APLICADO.sql")]
    ids = set()
    for a in archivos:
        with open(a, encoding="utf-8") as f:
            ids.update(UUID_RE.findall(f.read()))
    ids = sorted(ids)

    conn = db.conectar()
    try:
        cur = conn.cursor()
        cur.execute("SELECT count(*) FROM sign_samples WHERE video_uri LIKE %s "
                    "AND estado <> 'rechazada'", (prefijo,))
        n_ds = cur.fetchone()[0]
        n_rest = 0
        if ids:
            cur.execute(
                "SELECT count(*) FROM sign_samples WHERE (id = ANY(%s::uuid[]) "
                "OR derivada_de = ANY(%s::uuid[])) AND estado = 'rechazada' "
                "AND (video_uri IS NULL OR video_uri NOT LIKE %s)", (ids, ids, prefijo))
            n_rest = cur.fetchone()[0]
        log(f"  muestras del dataset que dejan de usarse: {n_ds}")
        log(f"  muestras tuyas que vuelven a 'aprobada': {n_rest}"
            + (f"  (de {len(archivos)} archivo(s) restaurar_propias)" if archivos else
               "  (no hay restaurar_propias_*.sql: no desplazo nada)"))
        if seco:
            conn.rollback()
            return n_ds, n_rest
        cur.execute("UPDATE sign_samples SET estado = 'rechazada' WHERE video_uri LIKE %s "
                    "AND estado <> 'rechazada'", (prefijo,))
        if ids:
            cur.execute(
                "UPDATE sign_samples SET estado = 'aprobada' WHERE (id = ANY(%s::uuid[]) "
                "OR derivada_de = ANY(%s::uuid[])) AND estado = 'rechazada' "
                "AND (video_uri IS NULL OR video_uri NOT LIKE %s)", (ids, ids, prefijo))
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    for a in archivos:                       # que no se vuelvan a aplicar por error
        os.replace(a, a[:-len(".sql")] + "_APLICADO.sql")
    return n_ds, n_rest


# ---------------------------------------------------------------------------
# 8. Exportar plantillas.json a los dos destinos
# ---------------------------------------------------------------------------
def exportar(args):
    estampa = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    hechos = []
    for i, destino in enumerate(args.destinos):
        carpeta = os.path.dirname(destino)
        if not os.path.isdir(carpeta):
            log(f"  (no existe {carpeta}; salto ese destino)")
            continue
        if os.path.exists(destino):
            os.makedirs(args.respaldo, exist_ok=True)
            copia = os.path.join(args.respaldo, f"{i}_{estampa}_plantillas.json")
            shutil.copy2(destino, copia)
            log(f"  respaldo: {copia}")
        r = subprocess.run([sys.executable, os.path.join(HERE, "exportar_paquete.py"),
                            "--salida", destino])
        if r.returncode != 0:
            raise SystemExit(f"exportar_paquete.py fallo para {destino}")
        hechos.append(destino)
    return hechos


# ---------------------------------------------------------------------------
# Principal
# ---------------------------------------------------------------------------
def escribir_creditos(carpeta_datos, cfg):
    """Una seccion por dataset en CREDITOS.md; al importar otro no se borran los demas."""
    ruta = os.path.join(carpeta_datos, "CREDITOS.md")
    cabecera = "# Datasets de LSM usados en UNIVOZ\n\n"
    seccion = (f"## {cfg['titulo']}\n\n"
               f"- Licencia: {cfg['licencia']} (obliga a dar credito)\n"
               f"- Cita: {cfg['cita']}\n"
               f"- Importado: {datetime.date.today().isoformat()}\n\n"
               "Texto sugerido para la pantalla \"Acerca de\" de la app:\n\n"
               f"> Parte del vocabulario viene del dataset \"{cfg['titulo']}\" "
               f"{cfg['credito']}\n")
    secciones = []
    if os.path.exists(ruta):
        with open(ruta, encoding="utf-8") as f:
            previo = f.read()
        if previo.startswith(cabecera):
            previo = previo[len(cabecera):]
        secciones = [x for x in re.split(r"(?m)^(?=## )", previo) if x.strip()]
    secciones = [x for x in secciones if not x.startswith(f"## {cfg['titulo']}\n")]
    secciones.append(seccion)
    with open(ruta, "w", encoding="utf-8") as f:
        f.write(cabecera + "\n".join(x.rstrip("\n") + "\n" for x in secciones))
    return ruta


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dataset", choices=sorted(DATASETS), default="medico")
    ap.add_argument("--carpeta", help="carpeta con los videos ya descomprimidos")
    ap.add_argument("--datos", default=DATOS_DEFECTO,
                    help="donde guardar descarga, videos y cache (~6 GB)")
    ap.add_argument("--sujetos", default="expertos",
                    help="'expertos' (defecto), 'todos', o una lista: 0,11,3")
    ap.add_argument("--probar", type=int, metavar="N",
                    help="procesa solo N videos y se detiene, sin tocar base ni plantillas")
    ap.add_argument("--empalmes", choices=["dataset", "dataset-siempre", "ambas"],
                    default="ambas",
                    help="senas que ya tenias: 'ambas' (defecto) = se suman y no se quita nada; "
                         "'dataset' = el dataset pesa mas (tus muestras quedan 'rechazada', "
                         "reversible) siempre que tu muestra se parezca mas a esa sena del "
                         "dataset que a otra; 'dataset-siempre' = igual pero sin verificar. "
                         "OJO: en la prueba con los videos reales las dos expertas NO se "
                         "reconocen entre si, asi que desplazar tus muestras por las del "
                         "dataset no se recomienda")
    ap.add_argument("--deshacer", action="store_true",
                    help="devuelve la base a como estaba antes del dataset: las muestras del "
                         "dataset quedan 'rechazada', las tuyas que desplazo vuelven a "
                         "'aprobada' (usa los restaurar_propias_*.sql) y regenera plantillas.json")
    ap.add_argument("--rehacer", action="store_true",
                    help="--deshacer y luego importa de nuevo con el recorte actual")
    ap.add_argument("--acuerdo", type=float, default=0.5,
                    help="fraccion de tus muestras que deben parecerse mas a esa sena del "
                         "dataset que a cualquier otra sena del dataset para que se considere "
                         "la MISMA sena y el dataset la desplace (defecto 0.5)")
    ap.add_argument("--como-pendientes", action="store_true",
                    help="todo entra 'pendiente' para revisarlo en tu pagina antes de aprobar")
    ap.add_argument("--sin-recorte", action="store_true")
    ap.add_argument("--espejo", action="store_true",
                    help="cruza izquierda y derecha (solo si el video estuviera espejeado)")
    ap.add_argument("--sin-prueba", action="store_true")
    ap.add_argument("--seco", action="store_true",
                    help="no escribe en la base ni exporta; solo dice que haria")
    ap.add_argument("--sin-base", action="store_true", help="solo prepara y reporta")
    ap.add_argument("--sin-exportar", action="store_true")
    ap.add_argument("--destinos", nargs="+", default=DESTINOS_DEFECTO,
                    help="plantillas.json a regenerar")
    ap.add_argument("--respaldo", default=RESPALDO_DEFECTO)
    ap.add_argument("--pose-model", default=os.path.join(ASSETS, "pose_landmarker_lite.task"))
    ap.add_argument("--hand-model", default=os.path.join(ASSETS, "hand_landmarker.task"))
    args = ap.parse_args()

    global _LOG
    os.makedirs(args.datos, exist_ok=True)
    gi = os.path.join(args.datos, ".gitignore")
    if not os.path.exists(gi):
        with open(gi, "w") as f:
            f.write("*\n")                      # 6 GB que no deben entrar a git
    _LOG = os.path.join(args.datos, "importacion.log")
    for flujo in (sys.stdout, sys.stderr):
        try:
            flujo.reconfigure(errors="replace")
        except Exception:
            pass

    cfg = DATASETS[args.dataset]
    if cfg.get("solo_pendientes"):
        args.como_pendientes = True          # no se sabe quien firma: nada se aprueba solo
        args.sin_exportar = True             # y plantillas.json (la app) no cambia
    log("=" * 70)
    log(f"{cfg['titulo']}  [{cfg['licencia']}]")
    log(f"{datetime.datetime.now():%Y-%m-%d %H:%M}   datos en: {args.datos}")
    log("=" * 70)

    if args.deshacer:
        log("\nDeshacer: el dataset deja de usarse y tus muestras vuelven" + ("  (--seco)" if args.seco else ""))
        deshacer(cfg, args.datos, seco=args.seco)
        if args.seco or args.sin_exportar:
            log("\n(no se exporta plantillas.json)")
            return
        log("\n[6] plantillas.json")
        for d in exportar(args):
            try:
                with open(d, encoding="utf-8") as f:
                    p = json.load(f)
                log(f"  {d}: {p['n_senas']} senas, {p['n_plantillas']} plantillas")
            except Exception as e:
                log(f"  {d}: no pude releerlo ({e})")
        log("\nListo. 'flutter run' completo para que la app tome el plantillas.json.")
        return

    if cfg.get("solo_pendientes") or args.sujetos == "todos":
        sujetos = None
    elif args.sujetos == "expertos":
        sujetos = set(cfg["expertos"])
    else:
        sujetos = {int(x) for x in args.sujetos.split(",") if x.strip()}

    # -- 1 y 2: bajar y descomprimir ---------------------------------------
    if args.carpeta:
        carpeta_videos = args.carpeta
        log(f"\n[1-2] usando videos de {carpeta_videos}")
    else:
        log("\n[1] Descarga")
        carpeta_dl = os.path.join(args.datos, f"{cfg['origen']}_{cfg['zenodo']}")
        carpeta_videos = os.path.join(carpeta_dl, "videos")
        if cfg.get("descarga") == "wikisigns":
            if not (os.path.isdir(carpeta_videos) and any(os.scandir(carpeta_videos))):
                ayuda = cfg.get("ayuda_descarga") or (
                    "    python tools/wikisigns_a_enlaces.py     # arma la lista\n"
                    "    python tools/descargar_wikisigns.py     # baja los videos")
                raise SystemExit(
                    "primero baja los videos (no se bajan solos):\n" + ayuda + "\n"
                    f"o usa  --carpeta <carpeta con una subcarpeta por palabra>   (esperaba {carpeta_videos})")
            log(f"  usando los videos ya bajados en {carpeta_videos}")
        elif cfg.get("descarga") == "mendeley":
            # ~10.7 GB; descargar_iteso.py reanuda y verifica cada archivo (conviene
            # correrlo antes por separado: python tools/descargar_iteso.py)
            hay = os.path.isdir(carpeta_videos) and any(os.scandir(carpeta_videos))
            if hay:
                log(f"  usando los videos ya bajados en {carpeta_videos}")
                man = os.path.join(carpeta_dl, "manifiesto_iteso.json")
                if os.path.exists(man) and not args.probar:
                    with open(man, encoding="utf-8") as f:
                        esperados = len(json.load(f))
                    bajados = sum(1 for x in os.scandir(carpeta_videos)
                                  if x.name.lower().endswith((".mp4", ".mov")))
                    if bajados < esperados:
                        log(f"  OJO: hay {bajados} videos y el manifiesto dice {esperados}; "
                            "corre  python tools/descargar_iteso.py  para completar")
            elif args.seco or args.probar:
                raise SystemExit("primero baja los videos:  python tools/descargar_iteso.py "
                                 "(con --probar 6 para solo unos pocos)")
            else:
                import descargar_iteso
                argv_viejo, sys.argv = sys.argv, [sys.argv[0], "--destino", carpeta_videos]
                try:
                    if descargar_iteso.main():
                        raise SystemExit("la descarga no termino bien; vuelve a correr el mismo comando")
                finally:
                    sys.argv = argv_viejo
        else:
            archivo, _info = descargar(cfg, carpeta_dl)
            log("\n[2] Descompresion")
            descomprimir(archivo, carpeta_videos)

    videos, ignorados = listar_videos(carpeta_videos, cfg, sujetos)
    if not videos:
        todos, _ = listar_videos(carpeta_videos, cfg, None)
        if todos:
            raise SystemExit(
                f"encontre {len(todos)} videos pero ninguno de las personas pedidas. "
                f"Personas que hay: {sorted({v['sujeto'] for v in todos})}. "
                "Usa --sujetos con esos numeros (o --sujetos todos).")
        raise SystemExit(f"no encontre videos con el nombre esperado ({cfg['patron']}) en {carpeta_videos}")
    glosas = sorted({v["gloss"] for v in videos})
    log(f"\n{len(videos)} videos, {len(glosas)} senas, personas "
        f"{sorted({v['sujeto'] for v in videos})}"
        + (f"  ({len(ignorados)} archivos con otro nombre, ignorados)" if ignorados else ""))

    if args.probar:
        por_sena = {}
        for v in videos:
            por_sena.setdefault(v["gloss"], []).append(v)
        nombres = sorted(por_sena)
        personas = max(1, len({v["sujeto"] for v in videos}))
        cuantas = max(1, min(len(nombres), -(-args.probar // personas)))
        if personas > args.probar:       # muchas personas (p. ej. 20): 1 video de cada una de N senas
            cuantas = max(1, min(len(nombres), args.probar))
        elegidas = [nombres[int(i * len(nombres) / cuantas)] for i in range(cuantas)]
        # por sena: tantos videos como haga falta para llegar a --probar (con dos personas, las dos;
        # con una sola persona, como ITESO, un video de cada una de N senas distintas)
        por_g = max(1, -(-max(args.probar, personas) // cuantas))
        if personas > args.probar:
            por_g = max(1, -(-args.probar // cuantas))
        videos = [v for g in elegidas for v in por_sena[g][:por_g]]
        if personas > args.probar:       # personas distintas en las distintas senas (no siempre la 1)
            videos = [por_sena[g][(i * 3) % len(por_sena[g])] for i, g in enumerate(elegidas)]
        log(f"modo prueba: {len(videos)} videos de {len(elegidas)} senas repartidas")

    # -- 3: landmarks -------------------------------------------------------
    log("\n[3] Landmarks y normalizacion")
    cache = os.path.join(args.datos, f"{cfg['origen']}_{cfg['zenodo']}", "cache")
    muestras = procesar_videos(videos, args, cache, cfg)
    buenas = [m for m in muestras if not m["motivo"]]
    malas = [m for m in muestras if m["motivo"]]

    ruta_csv = os.path.join(args.datos, "informe_dataset_lsm.csv")
    with open(ruta_csv, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["archivo", "gloss", "sujeto", "experto", "frames_video", "frames_usados",
                    "segundos_usados", "cola_repetida", "hombros_visibles", "con_mano",
                    "dos_manos", "descartada_por"])
        for m in muestras:
            w.writerow([m["archivo"], m["gloss"], m["sujeto"], int(m["experto"]),
                        m["n_frames_video"], m["n_frames"],
                        f"{m['n_frames'] / m['fps']:.2f}" if m.get("fps") else "",
                        m.get("cola_repetida", 0), f"{m['frac_validos']:.2f}",
                        f"{m['frac_con_mano']:.2f}", f"{m['frac_dos_manos']:.2f}",
                        m["motivo"] or ""])
    log(f"\n{len(buenas)} tomas buenas, {len(malas)} descartadas  (detalle: {ruta_csv})")
    if buenas:
        log(f"  {'cuadros con mano' if cfg.get('solo_mano') else 'hombros visibles'}: "
            f"{statistics.mean(m['frac_validos'] for m in buenas):.0%} "
            f"de los frames en promedio; manos: "
            f"{statistics.mean(m['frac_con_mano'] for m in buenas):.0%}; "
            f"frames por sena tras el recorte: "
            f"{statistics.median(m['n_frames'] for m in buenas):.0f} (mediana)")
    for m in malas[:15]:
        log(f"  descartada {m['archivo']}: {m['motivo']}")
    if len(malas) > 15:
        log(f"  ... y {len(malas) - 15} mas en el CSV")

    # -- lo que ya tienes ---------------------------------------------------
    ruta_actual, propias = cargar_paquete(
        args.destinos + [os.path.join(RAIZ, "assets", "plantillas.json")])
    glosas_propias = {g for g, _e, _s in propias}
    glosas_ds = {m["gloss"] for m in buenas}
    comunes = sorted(glosas_ds & glosas_propias)
    nuevas = sorted(glosas_ds - glosas_propias)
    log(f"\nContra tu diccionario actual ({len(glosas_propias)} senas"
        + (f", de {ruta_actual}" if ruta_actual else ", no encontre plantillas.json") + "):")
    log(f"  {len(nuevas)} senas NUEVAS, {len(comunes)} que ya tenias"
        + (": " + ", ".join(comunes) if 0 < len(comunes) <= 20 else ""))
    if glosas_ds and len(comunes) >= 0.8 * len(glosas_ds):
        log("  (casi todas ya estan: ese plantillas.json ya trae el dataset de una importacion "
            "anterior; es normal si usas --rehacer)")

    # -- 4: prueba entre expertos ------------------------------------------
    resultados = None
    if not args.sin_prueba and len(buenas) >= 2 and cfg["expertos"]:
        log("\n[4] Prueba entre las personas expertas (misma libreria, umbrales de la app)")
        resultados = prueba_entre_expertos(buenas, propias, cfg["expertos"])
        if resultados:
            conf = {}
            for r in resultados.values():
                conf.update(r["confusiones"])
            if conf:
                peor = sorted(conf.items(), key=lambda kv: kv[1] or 9)[:8]
                log("  confusiones mas cercanas (esperada -> reconocida, distancia):")
                for (esperada, vista), d in peor:
                    log(f"    {esperada} -> {vista}   {d}")

    acierto_exp, _dmed, txt_prueba = veredicto_prueba(resultados) if resultados else (None, None, None)
    if txt_prueba:
        log("\n  " + txt_prueba)

    if args.probar:
        log("\n--- RESULTADO DE LA PRUEBA ---")
        if len(buenas) < max(1, int(0.7 * len(muestras))):
            log("REVISA antes de seguir: menos del 70% de las tomas salio bien. Mira el "
                "CSV para ver el motivo.")
            sys.exit(2)                       # para que un .bat no siga con la importacion completa
        else:
            log("Las tomas salen bien con tu pipeline (hombros, manos, recorte).")
            if acierto_exp is None and cfg["expertos"]:
                log("(con tan pocos videos no se pudo medir si las dos expertas se reconocen "
                    "entre si; para eso corre la importacion completa con --sin-base)")
            log("Siguiente paso:  python tools/importar_dataset_lsm.py"
                + ("" if args.dataset == "medico" else f" --dataset {args.dataset}")
                + (f' --carpeta "{args.carpeta}"' if args.carpeta else ""))
        return

    # -- 5: base ------------------------------------------------------------
    if args.sin_base or not buenas:
        log("\n(--sin-base: termino aqui)")
        return
    log("\n[5] Base de datos" + ("  (--seco: no se escribe nada)" if args.seco else ""))
    if args.rehacer:
        log("  deshaciendo la importacion anterior:")
        deshacer(cfg, args.datos, seco=args.seco)
    r = importar_a_base(buenas, cfg, args, args.datos)
    log(f"  senas nuevas: {len(r['nuevas'])}   muestras {'a insertar' if args.seco else 'insertadas'}: "
        f"{r['muestras']}  (pendientes: {r['pendientes']}, ya estaban: {r['ya_estaban']})")
    if r["empalmes"]:
        log("  senas que ya tenias:")
        for e in r["empalmes"]:
            if e["decision"] == "dataset":
                txt = (f"gana el dataset ({e['dataset']} nuevas; tus {e['propias']} "
                       f"quedan 'rechazada')")
            elif args.empalmes == "ambas":
                txt = f"se suman ({e['dataset']} nuevas + tus {e['propias']})"
            else:
                vs = ", ".join(e["confundida_con"]) or "ninguna"
                txt = (f"OJO: solo {e['aciertos']} de tus {e['propias']} se parecen a esta sena "
                       f"del dataset (el resto, a: {vs}); puede ser OTRA sena o una "
                       f"variante, se conservan las dos")
            log(f"    {e['gloss']:<20} {txt}")
    if r.get("archivo_restaurar"):
        log(f"  para deshacer lo desplazado: {r['archivo_restaurar']}")
    ruta_cred = escribir_creditos(args.datos, cfg)
    log(f"  creditos (licencia {cfg['licencia']}): {ruta_cred}")

    if r["nuevas"]:
        ruta_nuevas = os.path.join(args.datos, "senas_nuevas.csv")
        with open(ruta_nuevas, "w", newline="", encoding="utf-8-sig") as f:
            w = csv.writer(f)
            w.writerow(["gloss", "espanol_asignado"])
            w.writerows(r["nuevas"])
        log(f"  textos en espanol asignados a las nuevas (revisalos): {ruta_nuevas}")

    # -- 6: exportar --------------------------------------------------------
    if args.seco or args.sin_exportar:
        log("\n(no se exporta plantillas.json)")
        return
    log("\n[6] plantillas.json")
    hechos = exportar(args)
    for d in hechos:
        try:
            with open(d, encoding="utf-8") as f:
                p = json.load(f)
            log(f"  {d}: {p['n_senas']} senas, {p['n_plantillas']} plantillas")
        except Exception as e:
            log(f"  {d}: no pude releerlo ({e})")
    log("\nListo. Ahora corre la app con 'flutter run' completo para que empaquete el "
        "plantillas.json nuevo (hot reload no lo toma).")


if __name__ == "__main__":
    main()
