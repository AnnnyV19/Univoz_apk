"""Pruebas del servidor local del visor (sesiones JSONL)."""

import json
import os
import sys
import tempfile
import threading
import urllib.request
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import servidor_visor as sv  # noqa: E402


def _levantar(tmp):
    srv = sv.crear("127.0.0.1", 0, sesiones=tmp)
    hilo = threading.Thread(target=srv.serve_forever, daemon=True)
    hilo.start()
    return srv, "http://127.0.0.1:%d" % srv.server_address[1]


def _post(url, cuerpo):
    req = urllib.request.Request(url, data=cuerpo.encode(), method="POST",
                                 headers={"Content-Type": "text/plain"})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def test_guarda_y_anexa_sesiones():
    with tempfile.TemporaryDirectory() as tmp:
        srv, base = _levantar(tmp)
        try:
            with urllib.request.urlopen(base + "/api/ping") as r:
                assert json.loads(r.read())["sessions"] is True
            a = '{"kind":"session_start"}\n{"kind":"frame","t":1}'
            assert _post(base + "/api/sesiones/20261002T1-abc123", a)[0] == 200
            assert _post(base + "/api/sesiones/20261002T1-abc123",
                         '{"kind":"frame","t":2}')[0] == 200
            with open(os.path.join(tmp, "20261002T1-abc123.jsonl")) as fh:
                lineas = [json.loads(l) for l in fh]
            assert [l["kind"] for l in lineas] == ["session_start", "frame",
                                                    "frame"]
            with urllib.request.urlopen(base + "/api/sesiones") as r:
                assert json.loads(r.read())["sessions"] == ["20261002T1-abc123"]
        finally:
            srv.shutdown()


def test_rechaza_ids_y_cuerpos_invalidos():
    with tempfile.TemporaryDirectory() as tmp:
        srv, base = _levantar(tmp)
        try:
            assert _post(base + "/api/sesiones/../../etc", "{}")[0] == 404
            assert _post(base + "/api/sesiones/abc", "{}")[0] == 404
            assert _post(base + "/api/sesiones/valido-123456", "no json")[0] == 400
            assert os.listdir(tmp) == []
        finally:
            srv.shutdown()


def test_sirve_el_visor():
    with tempfile.TemporaryDirectory() as tmp:
        srv, base = _levantar(tmp)
        try:
            url = base + "/assets/avatar_viewer/index.html"
            with urllib.request.urlopen(url) as r:
                assert r.status == 200
        finally:
            srv.shutdown()


if __name__ == "__main__":
    for nombre, fn in sorted(globals().items()):
        if nombre.startswith("test_"):
            fn()
            print("ok", nombre)
