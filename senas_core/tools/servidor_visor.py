"""Servidor local del visor: archivos estaticos + recepcion de sesiones.

Reemplaza a `python -m http.server` en `univoz.sh web`. Ademas de servir
senas_core/, acepta los registros de sesion del visor (SessionLogV1, JSONL)
y los guarda en senas_core/sesiones/<id>.jsonl para analizarlos con
tools/analizar_sesion.py. Solo escucha en la maquina local por defecto.

  python3 tools/servidor_visor.py --port 8080 --bind 127.0.0.1

Rutas:
  GET  /api/ping                 {"ok": true, "sessions": true}
  POST /api/sesiones/<id>        cuerpo: lineas JSONL; se anexan al archivo
  GET  /api/sesiones             lista de sesiones guardadas
"""

import argparse
import http.server
import json
import os
import re
import socketserver
import functools

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
SESIONES = os.path.join(ROOT, "sesiones")
ID_RE = re.compile(r"^[0-9A-Za-z_-]{6,64}$")
MAX_BODY = 8 * 1024 * 1024


class Manejador(http.server.SimpleHTTPRequestHandler):
    sesiones_dir = SESIONES

    def _json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/ping":
            return self._json(200, {"ok": True, "sessions": True})
        if self.path == "/api/sesiones":
            os.makedirs(self.sesiones_dir, exist_ok=True)
            items = sorted(f[:-6] for f in os.listdir(self.sesiones_dir)
                           if f.endswith(".jsonl"))
            return self._json(200, {"sessions": items})
        return super().do_GET()

    def do_POST(self):
        m = re.match(r"^/api/sesiones/([^/?#]+)$", self.path)
        if not m or not ID_RE.match(m.group(1)):
            return self._json(404, {"ok": False, "error": "ruta"})
        largo = int(self.headers.get("Content-Length") or 0)
        if largo <= 0 or largo > MAX_BODY:
            return self._json(413, {"ok": False, "error": "tamano"})
        cuerpo = self.rfile.read(largo).decode("utf-8", errors="replace")
        lineas = [l for l in cuerpo.split("\n") if l.strip()]
        for l in lineas:
            try:
                json.loads(l)
            except ValueError:
                return self._json(400, {"ok": False, "error": "jsonl"})
        os.makedirs(self.sesiones_dir, exist_ok=True)
        ruta = os.path.join(self.sesiones_dir, m.group(1) + ".jsonl")
        with open(ruta, "a", encoding="utf-8") as fh:
            fh.write("\n".join(lineas) + "\n")
        return self._json(200, {"ok": True, "lines": len(lineas)})

    def log_message(self, fmt, *args):
        if "/api/" in (args[0] if args else ""):
            return  # sin ruido por cada bloque de sesion
        super().log_message(fmt, *args)


class Servidor(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def crear(bind="127.0.0.1", port=8080, root=ROOT, sesiones=SESIONES):
    manejador = functools.partial(Manejador, directory=root)
    Manejador.sesiones_dir = sesiones
    return Servidor((bind, port), manejador)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8080)
    a = ap.parse_args()
    srv = crear(a.bind, a.port)
    print("visor en http://%s:%d  sesiones -> %s" % (a.bind, a.port, SESIONES))
    srv.serve_forever()
