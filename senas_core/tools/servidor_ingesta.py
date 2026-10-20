#!/usr/bin/env python3
"""Servidor local para subir senas desde un link, sin escribir comandos.

    python tools/servidor_ingesta.py

y abri http://127.0.0.1:8730 en el navegador.

QUE HACE: es una cara para los scripts que ya existen. No reimplementa
nada del pipeline -- los llama por subprocess y te muestra su salida en
vivo:

    descargar.py         baja el video del link
    segmentar_video.py   detecta donde empieza y termina cada sena
    ingest_segmentos.py  extrae landmarks y los sube a Supabase

Lo unico que agrega es la parte que hoy se hace a mano y es la mas
molesta: abrir la hoja de contactos en un visor, abrir el CSV en otro
lado, y escribir la palabra de cada segmento mirando de un lado al otro.
Aca las dos cosas estan en la misma pantalla.

SEGURIDAD: escucha solo en 127.0.0.1, asi que no es alcanzable desde la
red. Aun asi, toda ruta que llega por HTTP se valida contra la raiz del
proyecto (ver _ruta_segura): un servidor local que sirve archivos
arbitrarios del disco es un problema aunque solo vos lo puedas abrir.
"""

import importlib.util
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, AQUI)

import segmentos_csv  # noqa: E402

RAIZ = os.path.dirname(AQUI)
DESCARGAS = os.path.join(RAIZ, "videos", "descargados")
PAGINA = os.path.join(AQUI, "ingesta_web.html")

PUERTO = int(os.environ.get("UNIVOZ_PUERTO", "8730"))

# id -> {"estado", "log", "datos", "iniciado"}
_TRABAJOS = {}
_CANDADO = threading.Lock()

# Cuantos trabajos viejos conservar. Cada uno guarda su log completo en
# memoria; sin un tope, una sesion larga de ingesta los va acumulando.
_MAX_TRABAJOS = 40


def _ruta_segura(relativa):
    """Convierte una ruta que llego por HTTP en una ruta absoluta dentro
    del proyecto, o levanta ValueError.

    realpath resuelve '..' y los enlaces simbolicos ANTES de comparar, que
    es lo que impide que '../../../etc/passwd' o un symlink que apunte
    afuera se escapen de la raiz.
    """
    if not relativa:
        raise ValueError("falta la ruta")
    completa = os.path.realpath(os.path.join(RAIZ, relativa))
    raiz = os.path.realpath(RAIZ)
    if completa != raiz and not completa.startswith(raiz + os.sep):
        raise ValueError("ruta fuera del proyecto")
    return completa


def _relativa(absoluta):
    return os.path.relpath(absoluta, RAIZ).replace(os.sep, "/")


def _nuevo_trabajo():
    tid = uuid.uuid4().hex[:12]
    with _CANDADO:
        _TRABAJOS[tid] = {
            "estado": "corriendo",
            "log": [],
            "datos": {},
            "iniciado": time.time(),
        }
        if len(_TRABAJOS) > _MAX_TRABAJOS:
            viejos = sorted(_TRABAJOS.items(), key=lambda kv: kv[1]["iniciado"])
            for k, _ in viejos[: len(_TRABAJOS) - _MAX_TRABAJOS]:
                _TRABAJOS.pop(k, None)
    return tid


def _log(tid, linea):
    with _CANDADO:
        t = _TRABAJOS.get(tid)
        if t is not None:
            t["log"].append(linea.rstrip())


def _terminar(tid, estado, datos=None):
    with _CANDADO:
        t = _TRABAJOS.get(tid)
        if t is not None:
            t["estado"] = estado
            if datos:
                t["datos"].update(datos)


def _correr(tid, argumentos, al_terminar=None, terminar=True):
    """Corre un script del proyecto y vuelca su salida al log del trabajo.

    -u (unbuffered) es lo que hace que el progreso se vea en vivo: sin
    eso Python le pone buffer a stdout cuando no escribe a una terminal, y
    la pagina se quedaria en blanco hasta que el script termina.

    encoding/errors explicitos porque en Windows la consola no es UTF-8 y
    un acento en la salida tiraria UnicodeDecodeError justo a la mitad de
    una ingesta larga.
    """
    cmd = [sys.executable, "-u"] + argumentos
    # En Windows, un script que imprime a una pipe usa cp1252, no UTF-8. Esta
    # pagina decodifica como UTF-8, asi que "Señas" llegaba como "Se\ufffdas" y
    # las rutas con ñ o acentos (que imprime descargar.py) dejaban de existir.
    # Forzar UTF-8 en la salida de los hijos arregla la causa.
    entorno = dict(os.environ, PYTHONIOENCODING="utf-8")
    _log(tid, "$ " + " ".join(os.path.basename(a) if i < 3 else a
                              for i, a in enumerate(cmd)))
    try:
        proc = subprocess.Popen(
            cmd,
            cwd=RAIZ,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            env=entorno,
        )
    except OSError as e:
        _log(tid, f"no pude arrancar el proceso: {e}")
        if terminar:
            _terminar(tid, "error")
        return 1

    for linea in proc.stdout:
        _log(tid, linea)
    codigo = proc.wait()

    if codigo != 0:
        _log(tid, f"[el script termino con codigo {codigo}]")
        if terminar:
            _terminar(tid, "error")
        return codigo

    datos = al_terminar() if al_terminar else None
    if terminar:
        _terminar(tid, "ok", datos)
    return 0


def _lanzar(objetivo):
    tid = _nuevo_trabajo()
    threading.Thread(target=objetivo, args=(tid,), daemon=True).start()
    return tid


# ---------------------------------------------------------------- pasos


# Ultimo link descargado, por video. Sirve para que el boton de subtitulos
# no vuelva a pedir el link cuando ya se bajo desde aca.
_ULTIMO_LINK = {}

_EXT_VIDEO = (".mp4", ".mkv", ".webm", ".mov")


def _resolver_descarga(log, antes, inicio):
    """Ruta absoluta del video que acaba de bajar descargar.py, o None.

    Se lee de la linea "Listo: <ruta>  (N MB)". Pero esa ruta puede llegar
    deformada (acentos y ñ perdidos por la consola), asi que no se confia a
    ciegas: si no existe, se busca en la carpeta de descargas, en este orden,
    (a) un nombre que sea igual si se ignoran los caracteres no ASCII,
    (b) un archivo que no estaba antes, (c) uno tocado desde que empezo el
    trabajo. yt-dlp suele fechar el archivo con el dia de subida del video,
    asi que la fecha sola no alcanza."""
    leida = None
    for linea in reversed(log):
        m = re.match(r"^Listo:\s+(.*?)\s{2,}\(", linea)
        if m:
            leida = os.path.abspath(m.group(1))
            break
    if leida and os.path.exists(leida):
        return leida

    en_carpeta = _listar_descargas()

    def esqueleto(nombre):
        return re.sub(r"[^A-Za-z0-9]", "", nombre)

    if leida:
        clave = esqueleto(os.path.basename(leida))
        for v in en_carpeta:
            if esqueleto(v["nombre"]) == clave:
                return os.path.join(RAIZ, v["ruta"])
    for v in en_carpeta:
        if v not in antes:
            return os.path.join(RAIZ, v["ruta"])
    for v in en_carpeta:
        if v["mtime"] >= inicio - 2:
            return os.path.join(RAIZ, v["ruta"])
    return None


def _paso_descargar(cuerpo):
    url = (cuerpo.get("url") or "").strip()
    if not re.match(r"^https?://", url, re.I):
        raise ValueError("eso no parece un link (tiene que empezar con http)")
    nombre = (cuerpo.get("nombre") or "").strip()

    antes = _listar_descargas()

    def trabajo(tid):
        inicio = time.time()
        args = [os.path.join(AQUI, "descargar.py"), url]
        if nombre:
            args.append(nombre)

        def al_terminar():
            with _CANDADO:
                log = list(_TRABAJOS[tid]["log"])
            ruta = _resolver_descarga(log, antes, inicio)
            if ruta:
                rel = _relativa(ruta)
                _ULTIMO_LINK[rel] = url
                return {"video": rel, "url": url}
            return {}

        _correr(tid, args, al_terminar)

    return _lanzar(trabajo)


def _con_palabras(video):
    """Cuantas filas del CSV traen texto. Es lo que decide si un paso ya
    resolvio el trabajo o hay que seguir intentando."""
    return sum(1 for f in _leer_segmentos(video) if (f.get("palabra") or "").strip())


FUENTES = ("auto", "subtitulos", "texto", "voz", "imagen")

# Modulos de Python que hacen falta para cada fuente opcional. Cualquiera de
# la tupla sirve (rapidocr tiene dos nombres segun la version).
_MODULOS = {
    "voz": ("faster_whisper",),
    "texto": ("rapidocr", "rapidocr_onnxruntime", "easyocr"),
    "yt_dlp": ("yt_dlp",),
}
_INSTALAR = {
    "voz": "pip install faster-whisper",
    "texto": "pip install rapidocr onnxruntime",
}


def _herramientas():
    return {k: any(importlib.util.find_spec(m) is not None for m in mods)
            for k, mods in _MODULOS.items()}


def _paso_preparar(cuerpo):
    """Un solo boton: del link a la tabla lista para revisar.

    Encadena, y se detiene en cuanto una fuente da texto (en modo 'auto'):

      1. Bajar el video, si vino un link.
      2. Subtitulos DEL AUTOR: texto y tiempos exactos.
      3. Texto escrito dentro del video (OCR): rotulos y subtitulos quemados.
      4. La voz (Whisper, local): la persona dice la palabra mientras senia.
      5. Subtitulos automaticos de YouTube (tambien son voz, pero sin instalar
         nada).
      6. Deteccion por imagen: salen los cortes pero NO las palabras.

    Si la persona elige una fuente concreta, solo se prueba esa.

    El orden va de lo mas exacto a lo mas incierto. Las fuentes de texto
    (2, 3, 4, 5) exigen minimo de filas en modo 'auto' para no aceptar una
    sola lectura suelta del OCR como si fuera el resultado.
    """
    url = (cuerpo.get("url") or "").strip()
    video_rel = (cuerpo.get("video") or "").strip()
    if not url and not video_rel:
        raise ValueError("pega un link o elige un video ya descargado")
    if url and not re.match(r"^https?://", url, re.I):
        raise ValueError("eso no parece un link (tiene que empezar con http)")
    fuente = (cuerpo.get("fuente") or "auto").strip()
    if fuente not in FUENTES:
        raise ValueError(f"fuente desconocida: {fuente}")

    categoria = (cuerpo.get("categoria") or "").strip()
    esperado = cuerpo.get("esperado")
    video_abs = _ruta_segura(video_rel) if video_rel else None
    # Zona del rotulo marcada a mano en la pagina: [x0, y0, x1, y1] en 0..1.
    roi = cuerpo.get("roi")
    if roi:
        try:
            roi = [float(v) for v in roi]
            if len(roi) != 4 or not (0 <= roi[0] < roi[2] <= 1 and 0 <= roi[1] < roi[3] <= 1):
                raise ValueError
        except (TypeError, ValueError):
            raise ValueError("la zona marcada no es valida (x0,y0,x1,y1 entre 0 y 1)")
        if fuente not in ("auto", "texto"):
            roi = None

    def trabajo(tid):
        nonlocal video_abs, url
        # ---- 1. el video ----
        if video_abs is None:
            _log(tid, "== Bajando el video ==")
            antes = _listar_descargas()
            inicio = time.time()
            if _correr(tid, [os.path.join(AQUI, "descargar.py"), url],
                       terminar=False) != 0:
                _terminar(tid, "error")
                return
            with _CANDADO:
                log = list(_TRABAJOS[tid]["log"])
            video_abs = _resolver_descarga(log, antes, inicio)
            if video_abs is None:
                _log(tid, "baje el video pero no encuentro el archivo")
                _terminar(tid, "error")
                return
            _ULTIMO_LINK[_relativa(video_abs)] = url
        elif not url:
            url = _ULTIMO_LINK.get(_relativa(video_abs), "")

        datos = {"video": _relativa(video_abs), "url": url}
        hay = _herramientas()
        auto = fuente == "auto"

        def con_categoria(args):
            return args + (["--categoria", categoria] if categoria else [])

        def probar(titulo, args, id_fuente, minimo=1, si_queda_corto=None):
            """Corre una fuente. True si dejo al menos `minimo` filas con texto.
            `si_queda_corto` se llama si el script termino bien pero con poco
            texto (aun asi pudo dejar buenos cortes)."""
            _log(tid, "")
            _log(tid, f"== {titulo} ==")
            if _correr(tid, args, terminar=False) != 0:
                return False
            n = _con_palabras(video_abs)
            if n < minimo:
                _log(tid, f"(solo {n} fila(s) con texto: no me alcanza, sigo con otra fuente)")
                if si_queda_corto:
                    si_queda_corto()
                return False
            _marcar_fuente(video_abs, id_fuente)
            datos.update({"via": id_fuente, "salidas": _salidas_de(video_abs)})
            return True

        def falta(clave_h):
            _log(tid, "")
            if auto:
                _log(tid, f"(salto '{clave_h}': no esta instalado -- {_INSTALAR[clave_h]})")
            else:
                _log(tid, f"No esta instalado. En una terminal:  {_INSTALAR[clave_h]}")
                _terminar(tid, "error", datos)
            return False

        def subs(automaticos):
            a = [os.path.join(AQUI, "subtitulos.py"), "--video", video_abs]
            if url:
                a += ["--url", url]
            if automaticos:
                a.append("--aceptar-automaticos")
            return con_categoria(a)

        respaldo = segmentos_csv.ruta_csv(video_abs) + ".cortes_rotulo"
        if os.path.exists(respaldo):        # de una corrida anterior
            try:
                os.remove(respaldo)
            except OSError:
                pass

        def anotar_zona():
            """Deja en `datos` la zona del rotulo que uso el lector de texto,
            para que la pagina la dibuje sobre el video."""
            if roi:
                datos["zona"] = list(roi)
                return
            with _CANDADO:
                log = list(_TRABAJOS[tid]["log"])
            for linea in reversed(log):
                m = re.search(r"zona del rotulo: x ([\d.]+)-([\d.]+), y ([\d.]+)-([\d.]+)", linea)
                if m:
                    x0, x1, y0, y1 = (float(g) for g in m.groups())
                    datos["zona"] = [x0, y0, x1, y1]
                    return

        def guardar_cortes():
            """El lector de texto encontro los rotulos (los cortes) pero leyo
            pocas palabras. Esos cortes valen mas que los de la deteccion por
            imagen: se guardan por si ninguna otra fuente da texto."""
            if len(_leer_segmentos(video_abs)) >= 5:
                try:
                    shutil.copyfile(segmentos_csv.ruta_csv(video_abs), respaldo)
                except OSError:
                    pass

        def por_texto():
            if not hay["texto"]:
                return falta("texto")
            args = [os.path.join(AQUI, "ocr_rotulos.py"), "--video", video_abs]
            if roi:
                args += ["--roi", ",".join(f"{v:.4f}" for v in roi)]
            if esperado:
                args += ["--esperado", str(int(esperado))]
            hecho = probar("Leyendo el texto escrito en el video",
                           con_categoria(args), "texto", 3 if auto else 1,
                           si_queda_corto=guardar_cortes)
            if hecho:
                anotar_zona()
            return hecho

        def por_cortes_rotulo():
            """Ultimo recurso antes de cortar por imagen: los cortes que dejo
            el lector de texto aunque no haya podido leer las palabras."""
            if not os.path.exists(respaldo):
                return False
            try:
                shutil.copyfile(respaldo, segmentos_csv.ruta_csv(video_abs))
                os.remove(respaldo)
            except OSError:
                return False
            _marcar_fuente(video_abs, "imagen")
            n = len(_leer_segmentos(video_abs))
            _log(tid, "")
            _log(tid, f"LISTO: {n} corte(s) siguiendo los rotulos del video. "
                      "No pude leer las palabras: escribelas viendo cada clip.")
            datos.update({"via": "imagen", "cortes_rotulo": True,
                          "salidas": _salidas_de(video_abs)})
            anotar_zona()
            return True

        def por_voz():
            if not hay["voz"]:
                return falta("voz")
            return probar("Escuchando la voz del video",
                          con_categoria([os.path.join(AQUI, "voz.py"),
                                         "--video", video_abs]),
                          "voz", 3 if auto else 1)

        def por_imagen():
            _log(tid, "")
            _log(tid, "== Detectando por imagen (sin palabras) ==")
            args = [os.path.join(AQUI, "autoencuadre.py"), "--video", video_abs, "--json"]
            if esperado:
                args += ["--esperado", str(int(esperado))]
            with _CANDADO:
                marca = len(_TRABAJOS[tid]["log"])
            if _correr(tid, args, terminar=False) != 0:
                _log(tid, "")
                _log(tid, "No encontre rotulos en la imagen. Este video hay que "
                          "segmentarlo con los Ajustes manuales.")
                return False
            encuadre = None
            with _CANDADO:
                log = list(_TRABAJOS[tid]["log"][marca:])
            for linea in reversed(log):
                linea = linea.strip()
                if linea.startswith("{"):
                    try:
                        encuadre = json.loads(linea)
                    except ValueError:
                        pass
                    break
            if not encuadre or "roi" not in encuadre:
                _log(tid, "el buscador de encuadre no devolvio nada usable")
                return False
            _log(tid, "")
            _log(tid, "== Cortando las senas ==")
            args = [os.path.join(AQUI, "segmentar_video.py"), "--video", video_abs,
                    "--formato", "palabra", "--roi", encuadre["roi"],
                    "--senal", encuadre["senal"]]
            if encuadre.get("mascara_sep"):
                args.append("--mascara-sep")
            args = con_categoria(args)
            if _correr(tid, args, terminar=False) != 0:
                return False
            _marcar_fuente(video_abs, "imagen")
            n = len(_leer_segmentos(video_abs))
            _log(tid, "")
            _log(tid, f"LISTO: {n} segmento(s) por imagen. Las palabras faltan: "
                      "escribelas viendo cada clip.")
            datos.update({"via": "imagen", "encuadre": encuadre,
                          "salidas": _salidas_de(video_abs)})
            return True

        if fuente == "subtitulos":
            ok = probar("Buscando subtitulos del video", subs(True), "subtitulos")
        elif fuente == "texto":
            ok = por_texto() or por_cortes_rotulo()
        elif fuente == "voz":
            ok = por_voz()
        elif fuente == "imagen":
            ok = por_imagen()
        else:
            base = os.path.splitext(video_abs)[0]
            subs_locales = any(os.path.exists(base + suf)
                               for suf in (".es.vtt", ".vtt", ".es.srt", ".srt"))
            if not url and not subs_locales:
                _log(tid, "")
                _log(tid, "(sin link ni archivo de subtitulos junto al video: "
                          "salto la busqueda de subtitulos)")
            ok = (((url or subs_locales) and probar(
                      "Buscando subtitulos del autor", subs(False), "subtitulos"))
                  or (hay["texto"] and por_texto())
                  or (hay["voz"] and por_voz())
                  or (bool(url) and probar(
                      "Subtitulos automaticos de YouTube (son voz transcrita)",
                      subs(True), "subtitulos", 3))
                  or por_cortes_rotulo()
                  or por_imagen())
            # Solo si se llego hasta aqui sin que nada diera texto: ahi si
            # sirve saber que faltan dos herramientas por instalar.
            if datos.get("via") in (None, "imagen"):
                if not hay["texto"]:
                    _log(tid, "")
                    _log(tid, f"(para leer el texto escrito en el video: {_INSTALAR['texto']})")
                if not hay["voz"]:
                    _log(tid, f"(para escuchar la voz del video: {_INSTALAR['voz']})")

        # 'falta' ya marco el trabajo como error cuando se pidio una fuente
        # concreta que no esta instalada.
        with _CANDADO:
            ya = _TRABAJOS[tid]["estado"] != "corriendo"
        if ya:
            return
        if not ok:
            _log(tid, "")
            _log(tid, "Ninguna fuente dio resultado para este video.")
            _terminar(tid, "error", datos)
            return
        n = _con_palabras(video_abs)
        if n:
            _log(tid, "")
            _log(tid, f"LISTO: {n} sena(s) con texto (fuente: {datos.get('via')}).")
            _log(tid, "Ahora revisalas viendo cada clip y aprueba las buenas.")
        _terminar(tid, "ok", datos)

    return _lanzar(trabajo)


def _paso_subtitulos(cuerpo):
    """Arma los segmentos con la pista de subtitulos, si el video la trae.

    Es el camino corto: la pista da texto Y tiempos exactos, asi que no hay
    ROI que adivinar ni palabras que escribir. Si el video no tiene pista de
    autor, el script falla con un mensaje que lo explica y el flujo normal
    (autoencuadre + detectar) sigue disponible.
    """
    video = _ruta_segura(cuerpo.get("video"))
    args = [os.path.join(AQUI, "subtitulos.py"), "--video", video]
    url = (cuerpo.get("url") or "").strip()
    if url:
        args += ["--url", url]
    categoria = (cuerpo.get("categoria") or "").strip()
    if categoria:
        args += ["--categoria", categoria]
    if cuerpo.get("aceptar_automaticos"):
        args.append("--aceptar-automaticos")

    def trabajo(tid):
        _correr(tid, args, lambda: {"salidas": _salidas_de(video)})

    return _lanzar(trabajo)


def _paso_autoencuadre(cuerpo):
    """Busca solo la ROI, la senal y si hace falta tapar al interprete."""
    video = _ruta_segura(cuerpo.get("video"))
    args = [os.path.join(AQUI, "autoencuadre.py"), "--video", video, "--json"]
    esperado = cuerpo.get("esperado")
    if esperado:
        args += ["--esperado", str(int(esperado))]

    def trabajo(tid):
        def al_terminar():
            # autoencuadre.py --json imprime UNA linea de JSON al final.
            with _CANDADO:
                log = list(_TRABAJOS[tid]["log"])
            for linea in reversed(log):
                linea = linea.strip()
                if linea.startswith("{"):
                    try:
                        return {"encuadre": json.loads(linea)}
                    except ValueError:
                        break
            return {}

        _correr(tid, args, al_terminar)

    return _lanzar(trabajo)


def _paso_segmentar(cuerpo):
    video = _ruta_segura(cuerpo.get("video"))
    # --formato palabra NO es opcional aca: segmentar_video.py escribe por
    # defecto el formato 'gloss' (inicio,fin,gloss,espanol,categoria), que es
    # el que lee ingest_video_segmentos.py. Toda esta pagina termina en
    # ingest_segmentos.py, que exige n,inicio_s,fin_s,duracion_s,palabra --
    # sin esto la tabla sale vacia y la subida se rechaza.
    args = [os.path.join(AQUI, "segmentar_video.py"), "--video", video,
            "--formato", "palabra"]

    senal = (cuerpo.get("senal") or "").strip()
    if senal in ("tinta", "caja"):
        args += ["--senal", senal]

    roi = (cuerpo.get("roi") or "").strip()
    if roi:
        args += ["--roi", roi]
    if cuerpo.get("mascara_sep"):
        args.append("--mascara-sep")
    mascara = (cuerpo.get("mascara") or "").strip()
    if mascara:
        args += ["--mascara", mascara]
    categoria = (cuerpo.get("categoria") or "").strip()
    if categoria:
        args += ["--categoria", categoria]
    n_esperado = cuerpo.get("n_esperado")
    if n_esperado:
        args += ["--n-esperado", str(int(n_esperado))]
    if cuerpo.get("solo_roi"):
        args.append("--solo-roi")

    def trabajo(tid):
        _correr(tid, args, lambda: {"salidas": _salidas_de(video)})

    return _lanzar(trabajo)


def _paso_ingestar(cuerpo):
    video = _ruta_segura(cuerpo.get("video"))
    args = [os.path.join(AQUI, "ingest_segmentos.py"), "--video", video]

    if cuerpo.get("mascara_sep"):
        args.append("--mascara-sep")
    mascara = (cuerpo.get("mascara") or "").strip()
    if mascara:
        args += ["--mascara", mascara]
    signer = (cuerpo.get("signer") or "").strip()
    if signer:
        args += ["--signer", signer]
    categoria = (cuerpo.get("categoria") or "").strip()
    if categoria:
        args += ["--categoria", categoria]
    if cuerpo.get("manos") in (1, 2, "1", "2"):
        args += ["--manos", str(cuerpo["manos"])]
    if cuerpo.get("espejo"):
        args.append("--espejo")
    if cuerpo.get("es_estatica"):
        args.append("--es-estatica")
    if cuerpo.get("generar_espejo"):
        args.append("--generar-espejo")
    if cuerpo.get("aprobar"):
        args.append("--aprobar")
    if cuerpo.get("seco"):
        args.append("--seco")
    # La pagina siempre manda esto: solo se suben las filas que la persona
    # aprobo viendo el clip. Sin el flag, ingest_segmentos.py sube toda fila
    # con palabra (el comportamiento de siempre, para quien lo use a mano).
    if cuerpo.get("solo_aprobadas"):
        args.append("--solo-aprobadas")

    def trabajo(tid):
        _correr(tid, args)

    return _lanzar(trabajo)


# ------------------------------------------------------------- archivos


def _listar_descargas():
    if not os.path.isdir(DESCARGAS):
        return []
    videos = []
    for nombre in os.listdir(DESCARGAS):
        if os.path.splitext(nombre)[1].lower() not in (".mp4", ".mkv", ".webm", ".mov"):
            continue
        completa = os.path.join(DESCARGAS, nombre)
        try:
            st = os.stat(completa)
        except OSError:
            continue
        videos.append({
            "ruta": _relativa(completa),
            "nombre": nombre,
            "mb": round(st.st_size / (1024 * 1024), 1),
            "mtime": st.st_mtime,
        })
    videos.sort(key=lambda v: v["mtime"], reverse=True)
    return videos


def _salidas_de(video):
    """Las tres imagenes y el CSV que segmentar_video.py deja al lado del
    video. Se devuelve solo lo que exista: --solo-roi genera nada mas el
    .roi.png, y el perfil no siempre se puede dibujar."""
    base = os.path.splitext(video)[0]
    salidas = {}
    for clave, sufijo in (
        ("csv", ".segmentos.csv"),
        ("contactos", ".segmentos.png"),
        ("perfil", ".perfil.png"),
        ("roi", ".roi.png"),
    ):
        ruta = base + sufijo
        if os.path.exists(ruta):
            salidas[clave] = {
                "ruta": _relativa(ruta),
                # El navegador cachea las imagenes por URL. Sin esto, al
                # volver a segmentar con otra ROI se seguiria viendo la
                # hoja de contactos anterior.
                "v": int(os.path.getmtime(ruta)),
            }
    return salidas


def _leer_segmentos(video):
    """Devuelve las filas ya en el formato 'palabra'.

    Un CSV puede venir en el otro formato ('gloss': inicio,fin,gloss,espanol,
    categoria) si se genero a mano o con una corrida vieja. En vez de mostrar
    una tabla vacia sin explicacion, se traduce al vuelo: 'espanol' es el
    equivalente de 'palabra', y n/duracion se calculan.
    """
    import csv as _csv
    ruta = os.path.splitext(video)[0] + ".segmentos.csv"
    if not os.path.exists(ruta):
        return []
    with open(ruta, encoding="utf-8-sig", newline="") as f:
        crudas = [dict(fila) for fila in _csv.DictReader(f)]

    filas = []
    for i, c in enumerate(crudas, start=1):
        if "inicio_s" in c:
            filas.append(c)
            continue
        try:
            a = float(c.get("inicio") or 0)
            b = float(c.get("fin") or 0)
        except ValueError:
            continue
        filas.append({
            "n": str(i),
            "inicio_s": f"{a:.2f}",
            "fin_s": f"{b:.2f}",
            "duracion_s": f"{b - a:.2f}",
            "palabra": (c.get("espanol") or "").strip(),
            "categoria": (c.get("categoria") or "").strip(),
        })
    return filas


def _escribir_segmentos(video, filas):
    import csv as _csv
    ruta = segmentos_csv.ruta_csv(video)
    # Las columnas viven en segmentos_csv.py (las comparten voz.py,
    # ocr_rotulos.py y subtitulos.py). utf-8-sig: Excel abre los acentos
    # bien solo si el archivo lleva BOM.
    with open(ruta, "w", encoding="utf-8-sig", newline="") as f:
        w = _csv.DictWriter(f, fieldnames=segmentos_csv.COLUMNAS, extrasaction="ignore")
        w.writeheader()
        for fila in filas:
            w.writerow({c: fila.get(c, "") for c in segmentos_csv.COLUMNAS})
    return _relativa(ruta)


def _marcar_fuente(video, fuente):
    """Anota de donde salieron las filas (subtitulos.py y segmentar_video.py
    no escriben esa columna) y deja todas 'sin revisar'."""
    filas = _leer_segmentos(video)
    if not filas:
        return
    for f in filas:
        if not (f.get("fuente") or "").strip():
            f["fuente"] = fuente
        f.setdefault("aprobada", "")
    _escribir_segmentos(video, filas)


# --------------------------------------------------------------- HTTP


class Manejador(BaseHTTPRequestHandler):
    server_version = "UnivozIngesta/1.0"

    def log_message(self, formato, *args):
        # El log por defecto ensucia la consola con una linea por cada
        # sondeo de progreso (uno por segundo por trabajo).
        pass

    # -- utilidades de respuesta

    def _json(self, datos, codigo=200):
        cuerpo = json.dumps(datos, ensure_ascii=False).encode("utf-8")
        self.send_response(codigo)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(cuerpo)))
        self.end_headers()
        self.wfile.write(cuerpo)

    def _error(self, mensaje, codigo=400):
        self._json({"error": mensaje}, codigo)

    def _archivo(self, ruta, tipo=None):
        try:
            with open(ruta, "rb") as f:
                cuerpo = f.read()
        except OSError:
            return self._error("no encuentro el archivo", 404)
        self.send_response(200)
        self.send_header(
            "Content-Type",
            tipo or mimetypes.guess_type(ruta)[0] or "application/octet-stream",
        )
        self.send_header("Content-Length", str(len(cuerpo)))
        self.end_headers()
        self.wfile.write(cuerpo)

    def _video(self, ruta):
        """Sirve un video con soporte de Range.

        Sin esto el <video> de la pagina no puede saltar a la mitad: el
        navegador pide "bytes=N-" y, si le contestan 200 con el archivo entero
        (cientos de MB), o se queda cargando todo o ignora el salto. Con 206
        solo viaja el pedazo que se esta viendo."""
        try:
            total = os.path.getsize(ruta)
        except OSError:
            return self._error("no encuentro el video", 404)
        ini, fin, codigo = 0, total - 1, 200
        rango = (self.headers.get("Range") or "").strip()
        m = re.match(r"^bytes=(\d*)-(\d*)$", rango)
        if m and (m.group(1) or m.group(2)):
            a, b = m.groups()
            if a == "":                       # "ultimos N bytes"
                ini = max(0, total - int(b))
            else:
                ini = int(a)
                if b:
                    fin = min(int(b), total - 1)
            if ini > fin or ini >= total:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{total}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            codigo = 206
        self.send_response(codigo)
        self.send_header("Content-Type", mimetypes.guess_type(ruta)[0] or "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(fin - ini + 1))
        if codigo == 206:
            self.send_header("Content-Range", f"bytes {ini}-{fin}/{total}")
        self.end_headers()
        try:
            with open(ruta, "rb") as f:
                f.seek(ini)
                resta = fin - ini + 1
                while resta > 0:
                    trozo = f.read(min(256 * 1024, resta))
                    if not trozo:
                        break
                    self.wfile.write(trozo)
                    resta -= len(trozo)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            # El navegador corta la descarga cada vez que se salta a otro
            # tramo: es lo normal, no un error.
            pass

    def _cuerpo(self):
        largo = int(self.headers.get("Content-Length") or 0)
        if largo <= 0:
            return {}
        if largo > 5 * 1024 * 1024:
            raise ValueError("el cuerpo del pedido es demasiado grande")
        return json.loads(self.rfile.read(largo).decode("utf-8"))

    # -- rutas

    def do_GET(self):
        partes = urlparse(self.path)
        ruta = partes.path
        consulta = parse_qs(partes.query)

        if ruta in ("/", "/index.html"):
            if not os.path.exists(PAGINA):
                return self._error(
                    f"falta {os.path.basename(PAGINA)} al lado de este script", 500)
            return self._archivo(PAGINA, "text/html; charset=utf-8")

        if ruta == "/api/videos":
            return self._json({"videos": _listar_descargas(),
                               "links": _ULTIMO_LINK})

        if ruta == "/favicon.ico":
            # Sin esto el navegador lo pide y recibe un 404 en cada carga.
            self.send_response(204)
            self.end_headers()
            return

        if ruta == "/api/herramientas":
            return self._json(_herramientas())

        if ruta == "/api/video":
            try:
                completa = _ruta_segura((consulta.get("ruta") or [""])[0])
            except ValueError as e:
                return self._error(str(e))
            if os.path.splitext(completa)[1].lower() not in _EXT_VIDEO:
                return self._error("eso no es un video", 400)
            return self._video(completa)

        if ruta == "/api/trabajo":
            tid = (consulta.get("id") or [""])[0]
            with _CANDADO:
                t = _TRABAJOS.get(tid)
                if t is None:
                    return self._error("ese trabajo ya no existe", 404)
                # desde: el cliente solo pide las lineas nuevas, asi el
                # sondeo no reenvia un log de miles de lineas cada segundo.
                try:
                    desde = int((consulta.get("desde") or ["0"])[0])
                except ValueError:
                    desde = 0
                return self._json({
                    "estado": t["estado"],
                    "log": t["log"][desde:],
                    "total": len(t["log"]),
                    "datos": t["datos"],
                })

        if ruta == "/api/segmentos":
            try:
                video = _ruta_segura((consulta.get("video") or [""])[0])
            except ValueError as e:
                return self._error(str(e))
            return self._json({
                "filas": _leer_segmentos(video),
                "salidas": _salidas_de(video),
            })

        if ruta == "/api/archivo":
            try:
                completa = _ruta_segura((consulta.get("ruta") or [""])[0])
            except ValueError as e:
                return self._error(str(e))
            return self._archivo(completa)

        return self._error("no existe esa ruta", 404)

    def do_POST(self):
        ruta = urlparse(self.path).path
        try:
            cuerpo = self._cuerpo()
        except (ValueError, json.JSONDecodeError) as e:
            return self._error(f"cuerpo invalido: {e}")

        try:
            if ruta == "/api/descargar":
                return self._json({"trabajo": _paso_descargar(cuerpo)})
            if ruta == "/api/preparar":
                return self._json({"trabajo": _paso_preparar(cuerpo)})
            if ruta == "/api/subtitulos":
                return self._json({"trabajo": _paso_subtitulos(cuerpo)})
            if ruta == "/api/autoencuadre":
                return self._json({"trabajo": _paso_autoencuadre(cuerpo)})
            if ruta == "/api/segmentar":
                return self._json({"trabajo": _paso_segmentar(cuerpo)})
            if ruta == "/api/ingestar":
                return self._json({"trabajo": _paso_ingestar(cuerpo)})
            if ruta == "/api/segmentos":
                video = _ruta_segura(cuerpo.get("video"))
                filas = cuerpo.get("filas") or []
                if not isinstance(filas, list):
                    return self._error("filas tiene que ser una lista")
                return self._json({"csv": _escribir_segmentos(video, filas)})
        except ValueError as e:
            return self._error(str(e))

        return self._error("no existe esa ruta", 404)


def main():
    faltan = [n for n in ("descargar.py", "segmentar_video.py",
                          "ingest_segmentos.py", "autoencuadre.py",
                          "subtitulos.py", "voz.py", "ocr_rotulos.py",
                          "segmentos_csv.py")
              if not os.path.exists(os.path.join(AQUI, n))]
    if faltan:
        sys.exit(
            "faltan scripts en tools/: " + ", ".join(faltan) +
            "\nEste servidor no reimplementa el pipeline, solo los llama."
        )

    servidor = ThreadingHTTPServer(("127.0.0.1", PUERTO), Manejador)
    print(f"UNIVOZ - ingesta por link")
    print(f"  abri:  http://127.0.0.1:{PUERTO}")
    print(f"  raiz:  {RAIZ}")
    print("  (Ctrl+C para cerrar)")
    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        print("\nlisto, cerrado.")


if __name__ == "__main__":
    main()
