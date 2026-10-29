#!/usr/bin/env python3
"""Panel del recolector nocturno, en tu computadora.

    python tools/panel_recolector.py          (o doble clic a panel_recolector.bat)

y se abre http://127.0.0.1:8731 en el navegador.

QUÉ MUESTRA
  En vivo       En qué va el recolector (buscando, descargando, sacando
                landmarks, reconociendo...), la seña y el video de ahora,
                los contadores y lo último que dijo. Botones para correrlo
                ya (prueba sin descargar, o de verdad) y para detenerlo.
  Revisar       Cada muestra que trajo: el video al lado de su esqueleto
                (los landmarks guardados, animados), qué dijo el reconocedor
                y qué cree la IA. Tú decides:
                  Aprobar · Aprobar suavizada · Rechazar (con el motivo)
                  · Recortar y volver a sacar (el tramo bueno del video).
                Lo que ya aprobó solo también aparece, para confirmarlo.
  Aprendizaje   Qué aprendió de tus decisiones y cómo lo va a usar la
                próxima noche (aprendizaje_recolector.py).

Nada se borra: rechazar pone la muestra en 'rechazada'; suavizar guarda
antes una copia de los landmarks originales en
datasets_lsm/recolector/respaldo_landmarks/.

SEGURIDAD: escucha solo en 127.0.0.1. Las rutas de video que llegan por HTTP
se validan contra la carpeta del proyecto.

--demo: datos inventados, sin base ni MediaPipe (para probar la página).
"""
import argparse
import datetime as dt
import hmac
import secrets
import socket
import json
import math
import mimetypes
import os
import random
import re
import subprocess
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, AQUI)

import aprendizaje_recolector as ar  # noqa: E402

RAIZ = os.path.dirname(AQUI)
DATOS = os.path.join(RAIZ, "datasets_lsm", "recolector")
PAGINA = os.path.join(AQUI, "panel_recolector.html")
PUERTO = int(os.environ.get("UNIVOZ_PANEL_PUERTO", "8731"))
ASSETS = os.path.join(AQUI, "..", "android", "app", "src", "main", "assets")

_CANDADO = threading.Lock()
_TRABAJOS = {}          # id -> {"estado", "log", "resultado"}
_PROCESO = {"p": None}  # recolector lanzado desde el panel


def _ruta_segura(relativa):
    """Ruta relativa al proyecto -> absoluta, solo si queda dentro."""
    if not relativa:
        return None
    absoluta = os.path.abspath(os.path.join(RAIZ, relativa))
    if os.path.commonpath([absoluta, os.path.abspath(RAIZ)]) != os.path.abspath(RAIZ):
        return None
    return absoluta


def _ahora():
    return dt.datetime.now().isoformat(timespec="seconds")


# --------------------------------------------------------------------- base

class BaseReal:
    """Lo poco que el panel necesita de la base (Postgres/Supabase)."""

    def __init__(self):
        from dotenv import load_dotenv
        import db
        import sign_norm as sn
        load_dotenv(os.path.join(RAIZ, ".env"))
        load_dotenv()
        self.db, self.sn = db, sn
        self._conn = None
        self._candado = threading.Lock()
        self._clasif = None
        self._extractor = None

    def _c(self):
        if self._conn is None or self._conn.closed:
            self._conn = self.db.conectar()
        return self._conn

    def _hacer(self, fn):
        with self._candado:
            for intento in (0, 1):
                try:
                    return fn(self._c())
                except Exception:
                    try:
                        self._conn.rollback()
                    except Exception:
                        self._conn = None
                    if intento:
                        raise

    def estados(self, ids):
        ids = [i for i in ids if i]
        if not ids:
            return {}

        def f(conn):
            with conn.cursor() as cur:
                cur.execute("SELECT id::text, estado FROM sign_samples "
                            "WHERE id = ANY(%s::uuid[])", (ids,))
                return dict(cur.fetchall())
        return self._hacer(f)

    def landmarks(self, sample_id):
        def f(conn):
            with conn.cursor() as cur:
                cur.execute("SELECT data, frame_dim FROM sample_landmarks "
                            "WHERE sample_id = %s AND norm_version = %s",
                            (sample_id, self.sn.NORM_VERSION))
                fila = cur.fetchone()
            if not fila:
                return None
            return self.sn.unpack_f16(bytes(fila[0]), fila[1])
        return self._hacer(f)

    def poner_estado(self, sample_id, estado):
        def f(conn):
            with conn.cursor() as cur:
                cur.execute("UPDATE sign_samples SET estado = %s WHERE id = %s",
                            (estado, sample_id))
            conn.commit()
        self._hacer(f)

    def poner_landmarks(self, sample_id, seq):
        blob = self.sn.pack_f16(seq)

        def f(conn):
            with conn.cursor() as cur:
                cur.execute("UPDATE sample_landmarks SET data = %s "
                            "WHERE sample_id = %s AND norm_version = %s",
                            (blob, sample_id, self.sn.NORM_VERSION))
            conn.commit()
        self._hacer(f)

    def clasificador(self):
        if self._clasif is None:
            from dtw import DtwClassifier
            c = DtwClassifier()
            conteo = {}

            def f(conn):
                return self.db.plantillas_aprobadas(conn, self.sn.NORM_VERSION)
            for sign_id, gloss, espanol, data, _t, dim in self._hacer(f):
                c.add(sign_id, gloss, self.sn.unpack_f16(bytes(data), dim),
                      espanol=espanol or "")
                conteo[gloss] = conteo.get(gloss, 0) + 1
            self._clasif = (c, conteo)
        return self._clasif

    def reextraer(self, ev, desde, hasta, decir):
        """Vuelve a sacar la muestra con solo el tramo [desde, hasta]."""
        from ingest_video import ingest_un_video
        if self._extractor is None:
            from extraer_landmarks import ExtractorLandmarks
            decir("Cargando MediaPipe...")
            self._extractor = ExtractorLandmarks(
                os.path.join(ASSETS, "pose_landmarker_lite.task"),
                os.path.join(ASSETS, "hand_landmarker.task"))
        video = _ruta_segura(ev.get("video"))
        if not video or not os.path.exists(video):
            raise ValueError("no encuentro el video de esa muestra")
        decir(f"Sacando landmarks de {desde:.2f}s a {hasta:.2f}s...")

        def f(conn):
            r = ingest_un_video(conn, self._extractor, video_path=video,
                                gloss=ev["gloss"], espanol=ev.get("espanol") or "",
                                signer="recolector", aprobar=False,
                                desde=desde, hasta=hasta)
            conn.commit()
            return r
        r = self._hacer(f)
        seq = self.landmarks(str(r["sample_id"]))
        decir("Reconociendo...")
        c, conteo = self.clasificador()
        p = c.classify(seq)
        return r, p, c, conteo.get(ev["gloss"], 0) > 0


class BaseDemo:
    """Base inventada para probar la página sin Postgres."""

    def __init__(self):
        self._estados = {}
        self._lm = {}

    def _seq(self, sample_id):
        rnd = random.Random(sample_id)
        base = [0.0] * 152
        cuerpo = [(-0.5, 0, 0), (0.5, 0, 0), (-0.6, -0.8, 0.1), (0.6, -0.8, 0.1),
                  (-0.4, -1.4, 0.3), (0.4, -1.4, 0.3), (-0.3, -1.9, 0), (0.3, -1.9, 0)]
        for i, (x, y, z) in enumerate(cuerpo):
            base[i * 3:i * 3 + 3] = [x, y, z]
        mano = [(0.1 * math.cos(a), -0.6 - 0.25 * (j % 4), 0)
                for j, a in enumerate([k * 0.35 for k in range(20)])]
        seq = []
        for t in range(32):
            f = list(base)
            fase = math.sin(t / 31 * math.pi)
            for lado, loc, pres, shape in ((0, 24, 30, 32), (1, 27, 31, 92)):
                f[pres] = 1.0
                f[loc:loc + 3] = [(0.35 if lado else -0.35) + 0.1 * fase,
                                  -0.9 + 0.7 * fase, 0.3]
                for j, (x, y, z) in enumerate(mano):
                    f[shape + j * 3:shape + j * 3 + 3] = [
                        x * (1 if lado else -1), y + 0.15 * math.sin(t / 4 + j), z]
            if rnd.random() < 0.15:
                f[25] += 0.5            # un brinco para probar el suavizado
            # brazos siguen a las muñecas
            f[12:15] = [f[24], f[25], f[26]]
            f[15:18] = [f[27], f[28], f[29]]
            seq.append(f)
        return seq

    def estados(self, ids):
        return {i: self._estados.get(i, "pendiente") for i in ids if i}

    def landmarks(self, sample_id):
        return self._lm.get(sample_id) or self._seq(sample_id)

    def poner_estado(self, sample_id, estado):
        self._estados[sample_id] = estado

    def poner_landmarks(self, sample_id, seq):
        self._lm[sample_id] = seq

    def reextraer(self, ev, desde, hasta, decir):
        decir("(demo) sacando landmarks...")
        time.sleep(1)
        sid = f"demo-{random.randint(1000, 9999)}"

        class P:
            gloss = ev["gloss"]
            distance = 0.2
            margin = 0.5
            aceptada = True

        class C:
            max_distance = 0.55
            min_margin = 0.12
        return ({"sample_id": sid, "quality_score": 0.97, "n_frames": 60,
                 "frames_invalidos": 2, "fps": 30}, P(), C(), True)


def sembrar_demo(carpeta):
    """Eventos y estado inventados para --demo."""
    os.makedirs(carpeta, exist_ok=True)
    ev_ruta = os.path.join(carpeta, "eventos.jsonl")
    if os.path.exists(ev_ruta):
        return
    rnd = random.Random(7)
    glosas = [("CASA", "casa"), ("GRACIAS", "gracias"), ("ESCUELA", "escuela"),
              ("AMIGO", "amigo"), ("COMER", "comer"), ("AGUA", "agua")]
    canales = ["Señas MX", "Aprende LSM", "Canal Raro", "Wikisigns"]
    for k in range(18):
        g, e = glosas[k % len(glosas)]
        misma = rnd.random() < 0.7
        d = rnd.uniform(0.12, 0.6)
        ev = {"ts": _ahora(), "noche": "demo", "gloss": g, "espanol": e,
              "url": f"https://www.youtube.com/watch?v=demo{k:03d}",
              "fuente": "wikisigns" if k % 5 == 0 else "youtube",
              "canal": canales[k % len(canales)], "licencia": "Creative Commons",
              "titulo": f"{e.capitalize()} en LSM", "video": "",
              "sample_id": f"demo-{k:03d}", "calidad": round(rnd.uniform(0.7, 1.0), 3),
              "n_frames": 60, "frames_invalidos": rnd.randint(0, 12), "fps": 30,
              "prediccion": g if misma else "OTRA", "distancia": round(d, 4),
              "margen": round(rnd.uniform(0.05, 0.7), 3), "aceptada": misma and d < 0.55,
              "max_distancia": 0.55, "min_margen": 0.12, "hay_aprobadas": k % 7 != 0}
        ev["decision"] = "aprobada" if (misma and d < 0.3 and k % 3 == 0) else "pendiente"
        ev["motivo"] = "el reconocedor la confirma" if ev["decision"] == "aprobada" \
            else ("el reconocedor dice OTRA" if not misma else "distancia alta")
        ar.agregar_jsonl(ev_ruta, ev)
    with open(os.path.join(carpeta, "estado.json"), "w", encoding="utf-8") as f:
        json.dump({"corriendo": True, "pid": 0, "modo": "auto-aprobar",
                   "inicio": _ahora(), "actualizado": _ahora(),
                   "fase": "sacando landmarks",
                   "actual": {"i": 7, "n": 18, "gloss": "ESCUELA",
                              "url": "https://www.youtube.com/watch?v=demo007",
                              "titulo": "Escuela en LSM", "canal": "Aprende LSM",
                              "fuente": "youtube"},
                   "contadores": {"senas": 6, "candidatos": 31, "videos": 18,
                                  "hechos": 6, "aprobadas": 2, "pendientes": 3, "fallos": 1},
                   "log": ["== Recolector nocturno (demo)",
                           "   184 señas; 912 muestras aprobadas",
                           "   40 señas con menos de 10; esta noche se buscan 6",
                           "[6/18] AMIGO <- https://www.youtube.com/watch?v=demo005",
                           "   pendiente: margen bajo (0.14)",
                           "[7/18] ESCUELA <- https://www.youtube.com/watch?v=demo007"]},
                  f, ensure_ascii=False)


# ------------------------------------------------------------------ estado

def leer_estado():
    p = os.path.join(DATOS, "estado.json")
    if not os.path.exists(p):
        return {"corriendo": False, "fase": "nunca ha corrido", "log": [],
                "contadores": {}}
    try:
        with open(p, encoding="utf-8") as f:
            e = json.load(f)
    except (OSError, ValueError):
        return {"corriendo": False, "fase": "leyendo...", "log": [], "contadores": {}}
    # ¿Sigue vivo? Si dice que corre pero hace rato no escribe, se colgó o
    # se apagó la PC a medio camino.
    try:
        hace = (dt.datetime.now() - dt.datetime.fromisoformat(e.get("actualizado"))).total_seconds()
    except (TypeError, ValueError):
        hace = None
    e["hace_s"] = hace
    p_local = _PROCESO["p"]
    e["lanzado_aqui"] = p_local is not None and p_local.poll() is None
    if e.get("corriendo") and hace is not None and hace > 600 and not e["lanzado_aqui"]:
        e["colgado"] = True
    e["detener_pedido"] = os.path.exists(os.path.join(DATOS, "detener"))
    return e


def muestras(base, filtro):
    eventos = ar.leer_jsonl(os.path.join(DATOS, "eventos.jsonl"))
    revis = ar.ultima_revision(ar.leer_jsonl(os.path.join(DATOS, "revisiones.jsonl")))
    apr = ar.cargar(DATOS)
    eventos = [e for e in eventos if e.get("sample_id")]
    try:
        est = base.estados([e["sample_id"] for e in eventos])
    except Exception as ex:                       # sin base: se ve igual
        est = {}
        print("estados:", ex)
    out = []
    for e in reversed(eventos):
        r = revis.get(e["sample_id"])
        estado = est.get(e["sample_id"], e.get("decision"))
        d = dict(e)
        d["estado"] = estado
        d["revision"] = r
        p = ar.probabilidad_evento(apr, e)
        d["prob_ia"] = None if p is None else round(p, 3)
        d["tiene_video"] = bool(e.get("video")) and bool(_ruta_segura(e["video"])) \
            and os.path.exists(_ruta_segura(e["video"]))
        if filtro == "pendientes" and (r or estado != "pendiente"):
            continue
        if filtro == "auto" and (r or estado != "aprobada"):
            continue
        if filtro == "revisadas" and not r:
            continue
        out.append(d)
    return out


def reaprender():
    apr = ar.aprender(ar.leer_jsonl(os.path.join(DATOS, "eventos.jsonl")),
                      ar.leer_jsonl(os.path.join(DATOS, "revisiones.jsonl")))
    ar.guardar(DATOS, apr)
    return apr


def _evento_de(sample_id):
    for e in ar.leer_jsonl(os.path.join(DATOS, "eventos.jsonl")):
        if e.get("sample_id") == sample_id:
            return e
    return None


def revisar(base, cuerpo):
    sid = cuerpo.get("sample_id")
    decision = cuerpo.get("decision")
    if not sid or decision not in ("aprobar", "rechazar"):
        raise ValueError("falta la muestra o la decisión")
    acciones = [a for a in cuerpo.get("acciones") or [] if a in ("suavizado",)]
    motivos = [m for m in cuerpo.get("motivos") or [] if m in ar.MOTIVOS]
    if decision == "aprobar" and "suavizado" in acciones:
        seq = base.landmarks(sid)
        if seq:
            resp = os.path.join(DATOS, "respaldo_landmarks")
            os.makedirs(resp, exist_ok=True)
            with open(os.path.join(resp, f"{sid}.json"), "w", encoding="utf-8") as f:
                json.dump(seq, f)
            base.poner_landmarks(sid, ar.suavizar_mediana(seq))
    base.poner_estado(sid, "aprobada" if decision == "aprobar" else "rechazada")
    ar.agregar_jsonl(os.path.join(DATOS, "revisiones.jsonl"), {
        "ts": _ahora(), "sample_id": sid, "decision": decision,
        "motivos": motivos, "acciones": acciones, "nota": (cuerpo.get("nota") or "")[:300]})
    return reaprender()


def _trabajo(fn):
    tid = f"t{int(time.time() * 1000)}"
    with _CANDADO:
        _TRABAJOS[tid] = {"estado": "corriendo", "log": [], "resultado": None}

    def decir(texto):
        with _CANDADO:
            _TRABAJOS[tid]["log"].append(str(texto))

    def correr():
        try:
            res = fn(decir)
            with _CANDADO:
                _TRABAJOS[tid].update(estado="listo", resultado=res)
        except Exception as ex:
            decir(f"Error: {ex}")
            with _CANDADO:
                _TRABAJOS[tid]["estado"] = "error"
    threading.Thread(target=correr, daemon=True).start()
    return tid


def reextraer(base, cuerpo):
    sid = cuerpo.get("sample_id")
    ev = _evento_de(sid)
    if not ev:
        raise ValueError("no encuentro esa muestra en eventos.jsonl")
    desde, hasta = float(cuerpo.get("desde")), float(cuerpo.get("hasta"))
    if not (0 <= desde < hasta):
        raise ValueError("el tramo no es válido")

    def fn(decir):
        r, p, c, hay = base.reextraer(ev, desde, hasta, decir)
        nuevo = dict(ev)
        nuevo.update(ts=_ahora(), origen="recortada", de_muestra=sid,
                     desde=round(desde, 3), hasta=round(hasta, 3),
                     sample_id=str(r["sample_id"]),
                     calidad=round(r["quality_score"], 4),
                     n_frames=r.get("n_frames"),
                     frames_invalidos=r.get("frames_invalidos"),
                     prediccion=p.gloss,
                     distancia=None if p.distance == float("inf") else round(p.distance, 5),
                     margen=round(p.margin, 4), aceptada=bool(p.aceptada),
                     max_distancia=c.max_distance, min_margen=c.min_margin,
                     hay_aprobadas=hay, decision="pendiente",
                     motivo="recortada a mano: revísala")
        nuevo.pop("prob_ia", None)
        ar.agregar_jsonl(os.path.join(DATOS, "eventos.jsonl"), nuevo)
        # La original queda rechazada y marcada como "se recortó", sin contar
        # para aprender (no fue un sí ni un no a lo que trajo el recolector).
        base.poner_estado(sid, "rechazada")
        ar.agregar_jsonl(os.path.join(DATOS, "revisiones.jsonl"), {
            "ts": _ahora(), "sample_id": sid, "decision": "recortada",
            "motivos": ["cortada"] if cuerpo.get("cortada") else [],
            "acciones": ["recorte"], "nueva": nuevo["sample_id"]})
        decir(f"Lista: el reconocedor dice {p.gloss}.")
        return {"sample_id": nuevo["sample_id"], "prediccion": p.gloss}
    return _trabajo(fn)


def correr_recolector(modo):
    p = _PROCESO["p"]
    if p is not None and p.poll() is None:
        raise ValueError("ya está corriendo")
    e = leer_estado()
    if e.get("corriendo") and not e.get("colgado") and (e.get("hace_s") or 999) < 120:
        raise ValueError("ya está corriendo (lo lanzó la tarea nocturna)")
    args = [sys.executable, os.path.join(AQUI, "recolector_nocturno.py")]
    if modo == "seco":
        args.append("--seco")
    elif modo == "auto":
        args.append("--auto-aprobar")
    os.makedirs(DATOS, exist_ok=True)
    salida = open(os.path.join(DATOS, "ultima_panel.txt"), "w", encoding="utf-8")
    entorno = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUNBUFFERED="1")
    _PROCESO["p"] = subprocess.Popen(args, cwd=RAIZ, stdout=salida,
                                     stderr=subprocess.STDOUT, env=entorno)


def detener_recolector():
    os.makedirs(DATOS, exist_ok=True)
    with open(os.path.join(DATOS, "detener"), "w", encoding="utf-8") as f:
        f.write(_ahora())


def exportar():
    def fn(decir):
        decir("Moderando y exportando plantillas.json...")
        r = subprocess.run([sys.executable, os.path.join(AQUI, "moderar_senas.py"),
                            "--exportar"], cwd=RAIZ, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        for l in (r.stdout + r.stderr).splitlines()[-30:]:
            decir(l)
        decir("Listo." if r.returncode == 0 else f"Terminó con código {r.returncode}.")
        return r.returncode
    return _trabajo(fn)


# ----------------------------------------------------------------- red

COOKIE = "panel_clave"
_RED = {"activa": False, "clave": None, "urls": []}


def clave_panel():
    """Clave para entrar desde el celular. Se crea una vez y se guarda en
    datasets_lsm/recolector/clave_panel.txt (borrar ese archivo = clave nueva)."""
    p = os.path.join(DATOS, "clave_panel.txt")
    try:
        with open(p, encoding="utf-8") as f:
            c = f.read().strip()
        if len(c) >= 8:
            return c
    except OSError:
        pass
    c = secrets.token_urlsafe(9)
    os.makedirs(DATOS, exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(c)
    return c


def ips_locales():
    """IPs de esta PC en la red de la casa (sin mandar nada: un socket UDP
    'conectado' solo elige la interfaz)."""
    ips = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ips.append(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in ips and not ip.startswith("127."):
                ips.append(ip)
    except OSError:
        pass
    return ips


def es_local(ip):
    return ip in ("127.0.0.1", "::1") or ip.startswith("127.")


# ----------------------------------------------------------------- servidor

def crear_manejador(base, demo):
    class Manejador(BaseHTTPRequestHandler):
        def log_message(self, formato, *args):
            pass

        def _json(self, datos, codigo=200):
            cuerpo = json.dumps(datos, ensure_ascii=False).encode("utf-8")
            self.send_response(codigo)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(cuerpo)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(cuerpo)

        def _error(self, mensaje, codigo=400):
            self._json({"error": mensaje}, codigo)

        def _autorizado(self, q):
            """Desde esta PC siempre. Desde otro aparato (modo red) solo con
            la clave: la primera vez llega en el link (?clave=) y se guarda
            como cookie; sin ella no se ve nada."""
            if es_local(self.client_address[0]):
                return True
            if not _RED["activa"]:
                return False
            clave = _RED["clave"]
            for parte in (self.headers.get("Cookie") or "").split(";"):
                k, _, v = parte.strip().partition("=")
                if k == COOKIE and hmac.compare_digest(v, clave):
                    return True
            dada = (q.get("clave") or [""])[0]
            if dada and hmac.compare_digest(dada, clave):
                # Guarda la cookie y quita la clave de la barra de direcciones.
                self.send_response(303)
                self.send_header("Set-Cookie", f"{COOKIE}={clave}; Path=/; Max-Age=2592000; "
                                 "HttpOnly; SameSite=Strict")
                self.send_header("Location", "/")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return None
            return False

        def _sin_permiso(self):
            cuerpo = ("<!doctype html><meta charset=utf-8><meta name=viewport "
                      "content='width=device-width,initial-scale=1'><title>Recolector UNIVOZ</title>"
                      "<body style='font:17px system-ui;padding:32px;color:#29232F'>"
                      "<h2 style='color:#5B1493'>Falta la clave</h2><p>Abre el link completo "
                      "que aparece en el panel de tu PC (o escanea su código QR).</p>").encode("utf-8")
            self.send_response(403)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(cuerpo)))
            self.end_headers()
            self.wfile.write(cuerpo)

        def _cuerpo(self):
            largo = int(self.headers.get("Content-Length") or 0)
            if largo <= 0:
                return {}
            if largo > 1024 * 1024:
                raise ValueError("pedido demasiado grande")
            return json.loads(self.rfile.read(largo).decode("utf-8"))

        def _video(self, ruta):
            try:
                total = os.path.getsize(ruta)
            except OSError:
                return self._error("no encuentro el video", 404)
            ini, fin, codigo = 0, total - 1, 200
            m = re.match(r"^bytes=(\d*)-(\d*)$", (self.headers.get("Range") or "").strip())
            if m and (m.group(1) or m.group(2)):
                a, b = m.groups()
                if a == "":
                    ini = max(0, total - int(b))
                else:
                    ini = int(a)
                    if b:
                        fin = min(int(b), total - 1)
                if ini > fin or ini >= total:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{total}")
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
                pass

        def do_GET(self):
            u = urlparse(self.path)
            q = parse_qs(u.query)
            ruta = u.path
            ok = self._autorizado(q)
            if ok is None:
                return
            if not ok:
                return self._sin_permiso()
            try:
                if ruta == "/api/red":
                    local = es_local(self.client_address[0])
                    return self._json({
                        "activa": _RED["activa"],
                        "urls": [f"{u_}?clave={_RED['clave']}" for u_ in _RED["urls"]]
                        if local and _RED["activa"] else [],
                        "desde_celular": not local})
                if ruta in ("/", "/index.html"):
                    with open(PAGINA, "rb") as f:
                        cuerpo = f.read()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Content-Length", str(len(cuerpo)))
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    self.wfile.write(cuerpo)
                    return
                if ruta == "/api/estado":
                    return self._json({"estado": leer_estado(), "demo": demo})
                if ruta == "/api/muestras":
                    return self._json({"muestras": muestras(base, (q.get("filtro") or ["pendientes"])[0]),
                                       "motivos": ar.MOTIVOS})
                if ruta == "/api/landmarks":
                    seq = base.landmarks((q.get("id") or [""])[0])
                    if not seq:
                        return self._error("sin landmarks", 404)
                    return self._json({"frames": [[round(x, 4) for x in f] for f in seq]})
                if ruta == "/api/video":
                    r = _ruta_segura((q.get("ruta") or [""])[0])
                    if not r or not os.path.isfile(r):
                        return self._error("video fuera del proyecto o inexistente", 404)
                    return self._video(r)
                if ruta == "/api/aprendizaje":
                    apr = ar.cargar(DATOS) or reaprender()
                    return self._json({"aprendizaje": apr, "motivos": ar.MOTIVOS})
                if ruta == "/api/trabajo":
                    with _CANDADO:
                        t = _TRABAJOS.get((q.get("id") or [""])[0])
                        return self._json(dict(t) if t else {"estado": "no existe"})
                self._error("no existe", 404)
            except Exception as ex:
                self._error(str(ex), 500)

        def do_POST(self):
            u = urlparse(self.path)
            ruta = u.path
            if not self._autorizado({}):
                return self._error("falta la clave", 403)
            try:
                c = self._cuerpo()
                if ruta == "/api/revisar":
                    return self._json({"aprendizaje": revisar(base, c)})
                if ruta == "/api/reextraer":
                    return self._json({"trabajo": reextraer(base, c)})
                if ruta == "/api/correr":
                    if demo:
                        return self._error("en el modo demo no se corre el recolector")
                    correr_recolector(c.get("modo"))
                    return self._json({"ok": True})
                if ruta == "/api/detener":
                    detener_recolector()
                    return self._json({"ok": True})
                if ruta == "/api/exportar":
                    if demo:
                        return self._error("en el modo demo no se exporta")
                    return self._json({"trabajo": exportar()})
                if ruta == "/api/reaprender":
                    return self._json({"aprendizaje": reaprender()})
                self._error("no existe", 404)
            except ValueError as ex:
                self._error(str(ex))
            except Exception as ex:
                self._error(str(ex), 500)
    return Manejador


def main():
    global DATOS
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--demo", action="store_true", help="datos inventados, sin base")
    ap.add_argument("--puerto", type=int, default=PUERTO)
    ap.add_argument("--sin-navegador", action="store_true")
    ap.add_argument("--red", action="store_true",
                    help="también se abre desde el celular en la misma red Wi-Fi (con clave)")
    args = ap.parse_args()
    if args.demo:
        DATOS = os.path.join(RAIZ, "datasets_lsm", "recolector_demo")
        sembrar_demo(DATOS)
        base = BaseDemo()
    else:
        base = BaseReal()
    host = "127.0.0.1"
    if args.red:
        host = "0.0.0.0"
        _RED["activa"] = True
        _RED["clave"] = clave_panel()
        _RED["urls"] = [f"http://{ip}:{args.puerto}/" for ip in ips_locales()]
    srv = ThreadingHTTPServer((host, args.puerto), crear_manejador(base, args.demo))
    url = f"http://127.0.0.1:{args.puerto}"
    print(f"Panel del recolector en {url}  (Ctrl+C para cerrar)")
    if args.red:
        print("\nDesde el celular (misma red Wi-Fi), abre:")
        for u_ in _RED["urls"]:
            print(f"   {u_}?clave={_RED['clave']}")
        print("o escanea el código QR que sale en el panel de esta PC.")
        print("Si Windows pregunta por el Firewall, permite solo 'Redes privadas'.\n")
    if not args.sin_navegador:
        threading.Timer(0.8, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
