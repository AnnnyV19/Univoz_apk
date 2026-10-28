#!/usr/bin/env python3
"""Recolector nocturno: busca videos nuevos de señas, saca sus landmarks y
junta muestras para las señas que tienen pocas. Pensado para correr solo cada
noche en la PC (recolector_nocturno.bat + registrar_recolector.bat).

QUÉ HACE, en orden:
  1. Cuenta cuántas muestras APROBADAS tiene cada seña en la base.
  2. Elige las señas con menos de --objetivo (10) muestras, empezando por las
     que tienen menos, hasta --max-glosas por noche.
  3. Busca candidatos para cada una:
       - YouTube (yt-dlp, sin bajar nada todavía): "<palabra> LSM lengua de
         señas mexicana". Solo se queda con videos con licencia Creative
         Commons, cortos (<= --max-segundos) y cuyo título contiene la palabra.
       - Wikisigns, si existe videos/enlaces_wikisigns.txt (lo arma
         wikisigns_a_enlaces.py): las entradas de esas señas.
  4. Salta los links ya vistos (datasets_lsm/recolector/vistos.json).
  5. Baja cada candidato, saca landmarks con MediaPipe y lo guarda como
     muestra PENDIENTE (el mismo ingest_un_video de siempre).
  6. Verificación automática: reconoce la muestra nueva contra las aprobadas.
     Solo si el reconocedor dice LA MISMA seña, con distancia y margen holgados
     y buena calidad, la aprueba sola (--auto-aprobar, encendido en el .bat).
     Todo lo demás queda pendiente para que la dueña lo revise. Una seña que
     todavía no tiene ninguna muestra aprobada nunca se aprueba sola.
  7. Si aprobó algo, corre moderar_senas.py --exportar (palabras prohibidas y
     plantillas.json al día).
  8. Deja un reporte CSV por noche en datasets_lsm/recolector/.

EN VIVO Y APRENDIZAJE (panel_recolector.py):
  - estado.json: en qué va (fase, seña, video, contadores, últimas líneas).
  - eventos.jsonl: una línea por video con todo lo medido.
  - Si existe el archivo "detener", termina después del video en curso.
  - aprendizaje.json (aprendizaje_recolector.py, a partir de lo que la dueña
    revisa en el panel): canales y señas que ya no se buscan en YouTube,
    calidad mínima, suavizado y, con suficientes revisiones, la IA que
    decide qué aprobar solo.

DERECHOS: solo licencia Creative Commons (YouTube) o la que declare la entrada
de Wikisigns. Nada se publica: las muestras viven en la base de la dueña.

USO (desde senas_core):
    python tools/recolector_nocturno.py --seco          # solo busca y dice qué haría
    python tools/recolector_nocturno.py                 # baja y guarda como pendientes
    python tools/recolector_nocturno.py --auto-aprobar  # ... y aprueba las seguras
"""
import argparse
import csv
import datetime as dt
import json
import os
import subprocess
import sys
import time
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
RAIZ = os.path.abspath(os.path.join(HERE, ".."))
ASSETS = os.path.join(HERE, "..", "android", "app", "src", "main", "assets")
DATOS = os.path.join(RAIZ, "datasets_lsm", "recolector")
ENLACES_WIKISIGNS = os.path.join(RAIZ, "videos", "enlaces_wikisigns.txt")


def sin_acentos(texto):
    t = unicodedata.normalize("NFD", texto or "")
    return "".join(c for c in t if unicodedata.category(c) != "Mn").lower()


class Bitacora:
    """Lo que el panel lee para mostrar en vivo qué está haciendo."""

    def __init__(self, carpeta, modo):
        self.carpeta = carpeta
        self.ruta = os.path.join(carpeta, "estado.json")
        self.eventos = os.path.join(carpeta, "eventos.jsonl")
        self.datos = {
            "corriendo": True, "pid": os.getpid(), "modo": modo,
            "inicio": dt.datetime.now().isoformat(timespec="seconds"),
            "fase": "arrancando", "actual": None,
            "contadores": {"senas": 0, "candidatos": 0, "videos": 0,
                           "hechos": 0, "aprobadas": 0, "pendientes": 0,
                           "fallos": 0},
            "log": [],
        }
        self._ultimo = 0.0
        self.guardar(forzar=True)

    def decir(self, texto=""):
        print(texto, flush=True)
        for linea in str(texto).splitlines() or [""]:
            self.datos["log"].append(linea)
        del self.datos["log"][:-300]
        self.guardar()

    def fase(self, fase, actual=None):
        self.datos["fase"] = fase
        self.datos["actual"] = actual
        self.guardar(forzar=True)

    def contar(self, **kw):
        for k, v in kw.items():
            self.datos["contadores"][k] = self.datos["contadores"].get(k, 0) + v
        self.guardar()

    def poner(self, **kw):
        self.datos["contadores"].update(kw)
        self.guardar(forzar=True)

    def evento(self, dato):
        from aprendizaje_recolector import agregar_jsonl
        agregar_jsonl(self.eventos, dato)

    def terminar(self, fase="terminó"):
        self.datos["corriendo"] = False
        self.datos["fase"] = fase
        self.datos["actual"] = None
        self.datos["fin"] = dt.datetime.now().isoformat(timespec="seconds")
        self.guardar(forzar=True)

    def guardar(self, forzar=False):
        ahora = time.time()
        if not forzar and ahora - self._ultimo < 0.5:
            return
        self._ultimo = ahora
        self.datos["actualizado"] = dt.datetime.now().isoformat(timespec="seconds")
        try:
            os.makedirs(self.carpeta, exist_ok=True)
            tmp = self.ruta + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.datos, f, ensure_ascii=False)
            os.replace(tmp, self.ruta)
        except OSError:
            pass                      # el panel abierto puede bloquearlo un instante


def pidieron_detener():
    return os.path.exists(os.path.join(DATOS, "detener"))


def palabra_de(gloss, espanol):
    return (espanol or gloss.replace("_", " ")).strip()


# ----------------------------------------------------------------- decisión

def decidir(pred_gloss, gloss, distancia, margen, aceptada, calidad, *,
            max_distancia, min_margen, hay_aprobadas):
    """'aprobar' solo si es seguro; si no, 'pendiente' con el motivo.

    Seguro = el reconocedor dice la misma seña, aceptada, con distancia por
    debajo del 80 % del umbral y margen 1.5 veces el mínimo, y calidad >= 0.85.
    Puro (sin base ni red) para poder probarlo."""
    if not hay_aprobadas:
        return "pendiente", "la seña aún no tiene muestras aprobadas"
    if calidad < 0.85:
        return "pendiente", f"calidad baja ({calidad:.0%})"
    if pred_gloss != gloss:
        return "pendiente", f"el reconocedor dice {pred_gloss or 'nada'}"
    if not aceptada:
        return "pendiente", "reconocida pero sin seguridad"
    if distancia > 0.8 * max_distancia:
        return "pendiente", f"distancia alta ({distancia:.3f})"
    if margen < 1.5 * min_margen:
        return "pendiente", f"margen bajo ({margen:.2f})"
    return "aprobar", "el reconocedor la confirma"


def es_licencia_abierta(licencia):
    t = sin_acentos(licencia or "")
    return "creative commons" in t or t.startswith("cc ") or t.startswith("cc-")


def titulo_sirve(titulo, palabra):
    t = sin_acentos(titulo)
    return sin_acentos(palabra) in t


# ------------------------------------------------------------------ fuentes

def buscar_youtube(palabra, n, max_segundos, espera):
    """Candidatos de YouTube para `palabra` (sin bajar):
    [(url, licencia, título, canal)]."""
    from descargar import _cargar_yt_dlp
    YoutubeDL = _cargar_yt_dlp()
    consulta = f"ytsearch{n}:{palabra} LSM lengua de señas mexicana"
    out = []
    plano = {"quiet": True, "no_warnings": True, "extract_flat": True,
             "skip_download": True}
    with YoutubeDL(plano) as ydl:
        res = ydl.extract_info(consulta, download=False) or {}
    for e in res.get("entries") or []:
        url = e.get("url") or e.get("webpage_url")
        if not url:
            continue
        if not url.startswith("http"):
            url = f"https://www.youtube.com/watch?v={url}"
        titulo = e.get("title") or ""
        dur = e.get("duration")
        if dur and dur > max_segundos:
            continue
        if not titulo_sirve(titulo, palabra):
            continue
        time.sleep(espera)
        # La licencia solo viene en los metadatos completos.
        try:
            with YoutubeDL({"quiet": True, "no_warnings": True,
                            "skip_download": True, "noplaylist": True}) as ydl:
                info = ydl.extract_info(url, download=False) or {}
        except Exception as ex:  # video privado, borrado, etc.
            print(f"    (no pude leer {url}: {ex})")
            continue
        licencia = info.get("license") or ""
        if not es_licencia_abierta(licencia):
            continue
        if (info.get("duration") or 0) > max_segundos:
            continue
        canal = info.get("channel") or info.get("uploader") or ""
        out.append((url, licencia, titulo, canal))
    return out


def candidatos_wikisigns(glosas_buscadas):
    """Entradas de enlaces_wikisigns.txt de las palabras buscadas."""
    if not os.path.exists(ENLACES_WIKISIGNS):
        return {}
    por_palabra = {}
    with open(ENLACES_WIKISIGNS, encoding="utf-8") as f:
        for linea in f:
            linea = linea.strip()
            if not linea or linea.startswith("#"):
                continue
            partes = [p.strip() for p in linea.split(",")]
            if len(partes) < 2:
                continue
            por_palabra.setdefault(sin_acentos(partes[1]), []).append(partes[0])
    out = {}
    for gloss, palabra in glosas_buscadas.items():
        urls = por_palabra.get(sin_acentos(palabra), [])
        if urls:
            out[gloss] = [(u, "Wikisigns", palabra, "Wikisigns") for u in urls]
    return out


# ---------------------------------------------------------------- registro

def cargar_vistos():
    p = os.path.join(DATOS, "vistos.json")
    if os.path.exists(p):
        with open(p, encoding="utf-8") as f:
            return set(json.load(f))
    return set()


def guardar_vistos(vistos):
    os.makedirs(DATOS, exist_ok=True)
    p = os.path.join(DATOS, "vistos.json")
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(sorted(vistos), f, ensure_ascii=False, indent=0)
    os.replace(tmp, p)


# -------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--objetivo", type=int, default=10,
                    help="muestras aprobadas por seña que se buscan (default 10)")
    ap.add_argument("--max-glosas", type=int, default=40,
                    help="señas a buscar por noche (default 40)")
    ap.add_argument("--por-busqueda", type=int, default=6,
                    help="resultados de YouTube que se miran por seña")
    ap.add_argument("--max-videos", type=int, default=60,
                    help="videos que se bajan por noche como máximo")
    ap.add_argument("--max-segundos", type=int, default=30)
    ap.add_argument("--espera", type=float, default=2.0,
                    help="segundos entre consultas a YouTube (no saturar)")
    ap.add_argument("--sin-youtube", action="store_true")
    ap.add_argument("--sin-wikisigns", action="store_true")
    ap.add_argument("--auto-aprobar", action="store_true",
                    help="aprueba solas las muestras que el reconocedor confirma")
    ap.add_argument("--seco", action="store_true",
                    help="solo busca y escribe el plan; no baja ni toca la base")
    ap.add_argument("--signer", default="recolector")
    ap.add_argument("--pose-model", default=os.path.join(ASSETS, "pose_landmarker_lite.task"))
    ap.add_argument("--hand-model", default=os.path.join(ASSETS, "hand_landmarker.task"))
    args = ap.parse_args()

    from dotenv import load_dotenv
    import db
    import sign_norm as sn
    from dtw import DtwClassifier
    import aprendizaje_recolector as ar

    load_dotenv()
    os.makedirs(DATOS, exist_ok=True)
    try:
        os.remove(os.path.join(DATOS, "detener"))   # un "detener" viejo no cuenta
    except OSError:
        pass
    hoy = dt.datetime.now().strftime("%Y-%m-%d_%H%M")
    modo = "seco" if args.seco else ("auto-aprobar" if args.auto_aprobar else "pendientes")
    bit = Bitacora(DATOS, modo)
    try:
        _correr(args, bit, hoy, db, sn, DtwClassifier, ar)
    except BaseException as ex:
        bit.decir(f"ERROR: {ex}")
        bit.terminar("falló")
        raise
    detenido = pidieron_detener()
    bit.terminar("detenido" if detenido else "terminó")
    if detenido:
        try:
            os.remove(os.path.join(DATOS, "detener"))
        except OSError:
            pass


def _correr(args, bit, hoy, db, sn, DtwClassifier, ar):
    print = bit.decir                           # todo lo que dice va al panel
    # Lo aprendido de las revisiones (antes de empezar, con lo último).
    apr = ar.aprender(ar.leer_jsonl(os.path.join(DATOS, "eventos.jsonl")),
                      ar.leer_jsonl(os.path.join(DATOS, "revisiones.jsonl")))
    ar.guardar(DATOS, apr)
    max_segundos = min(args.max_segundos, apr.get("max_segundos", args.max_segundos))
    bloqueados = set(apr.get("canales_bloqueados") or [])
    sin_youtube = set(apr.get("glosas_sin_youtube") or [])
    print(f"== Recolector nocturno {hoy} ({bit.datos['modo']})")
    for l in apr.get("lecciones") or []:
        print(f"   aprendido: {l}")
    bit.fase("contando muestras")

    conn = db.conectar()
    # 1. Cuántas aprobadas tiene cada seña, y el reconocedor con todas ellas.
    clasif = DtwClassifier()
    conteo, espanol_de = {}, {}
    for sign_id, gloss, espanol, data, t_frames, frame_dim in \
            db.plantillas_aprobadas(conn, sn.NORM_VERSION):
        seq = sn.unpack_f16(bytes(data), frame_dim)
        clasif.add(sign_id, gloss, seq, espanol=espanol or "")
        conteo[gloss] = conteo.get(gloss, 0) + 1
        espanol_de[gloss] = espanol or ""
    # Señas que existen pero sin aprobadas también cuentan (con 0).
    with conn.cursor() as cur:
        cur.execute("SELECT gloss, espanol FROM signs")
        for gloss, espanol in cur.fetchall():
            conteo.setdefault(gloss, 0)
            espanol_de.setdefault(gloss, espanol or "")
    print(f"   {len(conteo)} señas; {sum(conteo.values())} muestras aprobadas")
    bit.fase("eligiendo señas")

    # 2. Las que tienen menos, primero. Sin letras sueltas (sus videos casi
    #    nunca se titulan con la letra sola).
    faltan = sorted((n, g) for g, n in conteo.items()
                    if n < args.objetivo and len(g) > 2)
    elegidas = {g: palabra_de(g, espanol_de.get(g)) for _, g in faltan[:args.max_glosas]}
    print(f"   {len(faltan)} señas con menos de {args.objetivo}; "
          f"esta noche se buscan {len(elegidas)}")
    bit.poner(senas=len(elegidas))

    # 3-4. Candidatos nuevos.
    vistos = cargar_vistos()
    cand = []
    if not args.sin_wikisigns:
        bit.fase("buscando en Wikisigns")
        for g, lista in candidatos_wikisigns(elegidas).items():
            for url, lic, tit, canal in lista:
                cand.append((g, url, lic, tit, "wikisigns", canal))
    if not args.sin_youtube:
        for k, (g, palabra) in enumerate(elegidas.items(), start=1):
            if pidieron_detener():
                break
            if g in sin_youtube:
                print(f"   {g}: no se busca en YouTube (aprendido)")
                continue
            bit.fase("buscando en YouTube", {"i": k, "n": len(elegidas),
                                             "gloss": g, "palabra": palabra})
            try:
                for url, lic, tit, canal in buscar_youtube(
                        palabra, args.por_busqueda, max_segundos, args.espera):
                    if canal in bloqueados:
                        print(f"   {g}: salto el canal {canal} (aprendido)")
                        continue
                    cand.append((g, url, lic, tit, "youtube", canal))
            except Exception as ex:
                print(f"   busqueda de {palabra}: {ex}")
            bit.poner(candidatos=len(cand))
            time.sleep(args.espera)
    nuevos, ya = [], set()
    for c in cand:
        if c[1] in vistos or c[1] in ya:
            continue
        ya.add(c[1])
        nuevos.append(c)
    nuevos = nuevos[:args.max_videos]
    print(f"   {len(nuevos)} videos nuevos para revisar")
    bit.poner(candidatos=len(cand), videos=len(nuevos))

    reporte = os.path.join(DATOS, f"reporte_{hoy}.csv")
    filas = []
    if args.seco:
        for g, url, lic, tit, fuente, canal in nuevos:
            filas.append({"gloss": g, "url": url, "fuente": fuente, "licencia": lic,
                          "titulo": tit, "canal": canal, "decision": "(seco)"})
            print(f"   {g:<24} {fuente:<9} {url}")
    else:
        from descargar import descargar
        from extraer_landmarks import ExtractorLandmarks
        from ingest_video import ingest_un_video

        extractor = ExtractorLandmarks(args.pose_model, args.hand_model)
        aprobadas = 0
        try:
            for i, (g, url, lic, tit, fuente, canal) in enumerate(nuevos, start=1):
                if pidieron_detener():
                    print("\nDetenido desde el panel.")
                    break
                print(f"\n[{i}/{len(nuevos)}] {g} <- {url}")
                actual = {"i": i, "n": len(nuevos), "gloss": g, "url": url,
                          "titulo": tit, "canal": canal, "fuente": fuente}
                fila = {"gloss": g, "url": url, "fuente": fuente,
                        "licencia": lic, "titulo": tit, "canal": canal}
                ev = {"ts": dt.datetime.now().isoformat(timespec="seconds"),
                      "noche": hoy, "gloss": g, "espanol": elegidas[g],
                      "url": url, "fuente": fuente, "canal": canal,
                      "licencia": lic, "titulo": tit}
                try:
                    bit.fase("descargando", actual)
                    vid = url.rsplit("=", 1)[-1].rsplit("/", 1)[-1][:16]
                    video = descargar(url, nombre=f"{g}_{vid}")
                    ev["video"] = os.path.relpath(video, RAIZ)
                    bit.fase("sacando landmarks", actual)
                    r = ingest_un_video(
                        conn, extractor, video_path=video, gloss=g,
                        espanol=elegidas[g], signer=args.signer, aprobar=False)
                    conn.commit()
                    fila.update(sample_id=r["sample_id"],
                                calidad=round(r["quality_score"], 3))
                    ev.update(sample_id=str(r["sample_id"]),
                              calidad=round(r["quality_score"], 4),
                              n_frames=r.get("n_frames"),
                              frames_invalidos=r.get("frames_invalidos"),
                              fps=r.get("fps"))
                    # 6. Verificación con el reconocedor.
                    bit.fase("reconociendo", actual)
                    with conn.cursor() as cur:
                        cur.execute(
                            "SELECT data, frame_dim FROM sample_landmarks "
                            "WHERE sample_id = %s AND norm_version = %s",
                            (r["sample_id"], sn.NORM_VERSION))
                        data, frame_dim = cur.fetchone()
                    seq = sn.unpack_f16(bytes(data), frame_dim)
                    if apr.get("suavizar"):
                        # Aprendido: quitar brincos de un cuadro (mediana de 3).
                        seq = ar.suavizar_mediana(seq)
                        with conn.cursor() as cur:
                            cur.execute(
                                "UPDATE sample_landmarks SET data = %s "
                                "WHERE sample_id = %s AND norm_version = %s",
                                (sn.pack_f16(seq), r["sample_id"], sn.NORM_VERSION))
                        conn.commit()
                        ev["suavizada"] = True
                    p = clasif.classify(seq)
                    ev.update(prediccion=p.gloss,
                              distancia=round(p.distance, 5) if p.distance != float("inf") else None,
                              margen=round(p.margin, 4), aceptada=bool(p.aceptada),
                              max_distancia=clasif.max_distance,
                              min_margen=clasif.min_margin,
                              hay_aprobadas=conteo.get(g, 0) > 0)
                    fija = decidir(
                        p.gloss, g, p.distance, p.margin, p.aceptada,
                        r["quality_score"],
                        max_distancia=clasif.max_distance,
                        min_margen=clasif.min_margin,
                        hay_aprobadas=conteo.get(g, 0) > 0)
                    decision, motivo = ar.decidir_aprendido(ev, apr, fija)
                    prob = ar.probabilidad_evento(apr, ev)
                    if prob is not None:
                        ev["prob_ia"] = round(prob, 3)
                    if decision == "aprobar" and args.auto_aprobar:
                        with conn.cursor() as cur:
                            cur.execute("UPDATE sign_samples SET estado = 'aprobada' "
                                        "WHERE id = %s", (r["sample_id"],))
                        conn.commit()
                        aprobadas += 1
                        estado = "aprobada"
                    else:
                        estado = "pendiente"
                    fila.update(prediccion=p.gloss, distancia=round(p.distance, 4),
                                margen=round(p.margin, 3), decision=estado, motivo=motivo)
                    ev.update(decision=estado, motivo=motivo)
                    bit.contar(hechos=1, **{"aprobadas" if estado == "aprobada" else "pendientes": 1})
                    print(f"   {estado}: {motivo}")
                except Exception as ex:
                    conn.rollback()
                    fila.update(decision="fallo", motivo=str(ex)[:200])
                    ev.update(decision="fallo", motivo=str(ex)[:300])
                    bit.contar(hechos=1, fallos=1)
                    print(f"   FALLO: {ex}")
                bit.evento(ev)
                vistos.add(url)
                guardar_vistos(vistos)
                filas.append(fila)
        finally:
            extractor.cerrar()
        # 7. Moderación y plantillas.json si cambió lo aprobado.
        if aprobadas:
            bit.fase("exportando plantillas")
            print(f"\n{aprobadas} aprobadas solas: moderando y exportando...")
            subprocess.run([sys.executable, os.path.join(HERE, "moderar_senas.py"),
                            "--exportar"], check=False)
    conn.close()

    campos = ["gloss", "url", "fuente", "canal", "licencia", "titulo", "sample_id",
              "calidad", "prediccion", "distancia", "margen", "decision", "motivo"]
    with open(reporte, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=campos, extrasaction="ignore")
        w.writeheader()
        w.writerows(filas)
    print(f"\nReporte: {reporte}")


if __name__ == "__main__":
    main()
