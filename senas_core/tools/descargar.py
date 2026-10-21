#!/usr/bin/env python3
"""Baja un video a partir de un link, para que la ingesta pueda recibir una
URL donde antes solo aceptaba una ruta de archivo.

Se apoya en yt-dlp, que ademas de YouTube soporta muchisimos otros sitios.

Los videos bajados quedan en videos/descargados/ y NO se borran, por dos
razones: poder abrirlos para revisar la muestra antes de aprobarla, y poder
reingerirlos sin volver a bajarlos cuando cambie la version de
normalizacion (que ya paso una vez, al migrar de 138 a 152 dimensiones).

DERECHOS: bajar videos de terceros puede ir contra los terminos de servicio
del sitio y contra la licencia del video. Para el diccionario de UNIVOZ lo
seguro son videos propios, o de terceros con permiso explicito o con
licencia abierta (Creative Commons). Esto importa mas si el dataset se va a
publicar o si la app se monetiza.

Tambien sirve suelto, para probar que un link baja bien antes de meterlo en
una lista larga:
    python tools/descargar.py "https://..."
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DESCARGAS = os.path.normpath(os.path.join(HERE, "..", "videos", "descargados"))

# Solo video, sin audio: para extraer landmarks el audio sobra, y al bajar un
# unico stream no hace falta ffmpeg para fusionar nada.
#
# Ojo con "best" a secas: en yt-dlp significa "el mejor formato que traiga
# video Y audio en el mismo archivo", y YouTube hace anios que los sirve por
# separado -- ahi no hay ningun formato que cumpla y falla con "Requested
# format is not available". "bv*" es lo correcto: el mejor formato que
# contenga video, tenga audio o no.
#
# Se prefiere avc1 (H.264) sobre VP9/AV1 porque es el que OpenCV decodifica
# sin problemas en cualquier instalacion; los otros a veces abren el archivo
# pero devuelven cero frames, que se ve como "el video no tiene frames
# legibles" mucho despues, en la ingesta.
FORMATO = (
    "bv*[vcodec^=avc1][height<=1080]"
    "/bv*[ext=mp4][height<=1080]"
    "/bv*[height<=1080]"
    "/bv*"
    "/b"
)


def es_url(origen):
    """True si `origen` parece un link y no una ruta de archivo."""
    return bool(re.match(r"^https?://", str(origen).strip(), re.I))


def nombre_seguro(texto, maximo=60):
    """Convierte un titulo en algo que Windows acepte como nombre de archivo."""
    limpio = re.sub(r"[^\w\s-]", "", str(texto), flags=re.UNICODE).strip()
    limpio = re.sub(r"[\s_-]+", "_", limpio)
    return limpio[:maximo] or "video"


def _cargar_yt_dlp():
    try:
        from yt_dlp import YoutubeDL
    except ImportError:
        raise ValueError(
            "para bajar videos por link hace falta yt-dlp. Instalalo con:\n"
            "    pip install yt-dlp\n"
            "(ya esta en tools/requirements.txt)"
        )
    return YoutubeDL


def titulo(url):
    """El titulo del video sin bajarlo -- para armar la glosa cuando la
    lista de links no trae una palabra escrita a mano."""
    YoutubeDL = _cargar_yt_dlp()
    opciones = {"quiet": True, "no_warnings": True, "noplaylist": True, "skip_download": True}
    try:
        with YoutubeDL(opciones) as ydl:
            info = ydl.extract_info(url, download=False)
    except Exception as e:
        raise ValueError(f"no pude leer el link ({e})")
    return (info or {}).get("title") or ""


def descargar(url, carpeta=None, nombre=None):
    """Baja `url` y devuelve la ruta local del archivo.

    `nombre` (sin extension) es como se va a llamar el archivo; pasale la
    glosa para que en videos/descargados/ se vea de un vistazo que es cada
    cosa. Si no se pasa, usa el titulo del video.

    Si el archivo ya existe no lo vuelve a bajar.

    Levanta ValueError con un mensaje pensado para mostrarse tal cual si el
    link no se puede bajar.
    """
    YoutubeDL = _cargar_yt_dlp()

    carpeta = carpeta or DESCARGAS
    os.makedirs(carpeta, exist_ok=True)

    plantilla = os.path.join(
        carpeta,
        (nombre_seguro(nombre) + ".%(ext)s") if nombre else "%(title).60B.%(ext)s",
    )
    opciones = {
        "format": FORMATO,
        "outtmpl": plantilla,
        "noplaylist": True,   # un link con &list= baja UN video, no la playlist entera
        "overwrites": False,  # si ya esta bajado, no lo vuelve a bajar
        "quiet": True,
        "no_warnings": True,
    }

    try:
        with YoutubeDL(opciones) as ydl:
            info = ydl.extract_info(url, download=True)
            ruta = ydl.prepare_filename(info)
    except ValueError:
        raise
    except Exception as e:
        raise ValueError(f"no pude bajar el video ({e})")

    if not os.path.exists(ruta):
        # yt-dlp puede haber guardado con otra extension que la que predijo
        base = os.path.splitext(ruta)[0]
        alternativas = [
            base + ext for ext in (".mp4", ".mkv", ".webm", ".mov")
            if os.path.exists(base + ext)
        ]
        if not alternativas:
            raise ValueError(f"se bajo pero no encuentro el archivo resultante: {ruta}")
        ruta = alternativas[0]

    return ruta


def resolver(origen, nombre=None):
    """Devuelve una ruta local a partir de `origen`, sea link o ruta.

    Es lo que usan los scripts de ingesta para aceptar las dos cosas en el
    mismo argumento.
    """
    if es_url(origen):
        return descargar(origen, nombre=nombre)
    if not os.path.exists(origen):
        raise ValueError(f"no existe el video: {origen}")
    return origen


def main():
    if len(sys.argv) < 2:
        sys.exit(f"uso: python {os.path.basename(__file__)} <url> [nombre]")
    url = sys.argv[1]
    nombre = sys.argv[2] if len(sys.argv) > 2 else None
    try:
        ruta = descargar(url, nombre=nombre)
    except ValueError as e:
        sys.exit(str(e))
    tam = os.path.getsize(ruta) / (1024 * 1024)
    print(f"Listo: {ruta}  ({tam:.1f} MB)")


if __name__ == "__main__":
    main()
