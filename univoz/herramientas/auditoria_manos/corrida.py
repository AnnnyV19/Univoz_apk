"""Corre cada seña por el visor real (headless) y guarda lo que hizo el avatar.
uso: corrida.py <entrada.npz> <salida.npz> [sep=1|0] [fps=30] [velgate=0] [pagina=auditoria.html]"""
import sys, time, json, os, threading, functools, http.server
import numpy as np
from playwright.sync_api import sync_playwright

ent, sal = sys.argv[1], sys.argv[2]
sep = (sys.argv[3] if len(sys.argv) > 3 else '1') == '1'
fps = float(sys.argv[4]) if len(sys.argv) > 4 else 30.0
velgate = float(sys.argv[5]) if len(sys.argv) > 5 else 0
pagina = sys.argv[6] if len(sys.argv) > 6 else 'auditoria.html'
z = np.load(ent)
glosas = list(z.files)
WWW = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'www')
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(
    type('H', (http.server.SimpleHTTPRequestHandler,), {'log_message': lambda *a: None}), directory=WWW))
threading.Thread(target=srv.serve_forever, daemon=True).start()
URL = 'http://127.0.0.1:%d/avatar_viewer/%s?standalone=1' % (srv.server_address[1], pagina)
out = {}
with sync_playwright() as p:
    b = p.chromium.launch(args=['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'])
    pg = b.new_page()
    errs = []
    pg.on('pageerror', lambda e: errs.append(str(e)))
    pg.goto(URL)
    for _ in range(200):
        if pg.evaluate('() => !!(window.__aud && window.__aud.listo())'): break
        time.sleep(0.3)
    meta = pg.evaluate('() => window.__aud.preparar()')
    if velgate: pg.evaluate('(v) => { window.__velGate = v; }', velgate)
    if not sep:
        pg.evaluate('() => window.__aud.config({separarCuerpo: false, separarManos: false})')
    t0 = time.time()
    for i, g in enumerate(glosas):
        pg.evaluate('() => window.__aud.reposo(40)')
        r = pg.evaluate('([f, fps]) => window.__aud.senar(f, fps, 40)', [z[g].tolist(), fps])
        n = len(r['pos'])
        out[g + '|pos'] = np.array(r['pos'], np.float32)
        out[g + '|alim'] = np.array(r['alim'], np.float32).reshape(n, 152)
        out[g + '|nodos'] = np.array(r['nodos'], np.float32).reshape(n, 46, 3)
        out[g + '|prep'] = np.array(r['prep'], np.float32)
        out[g + '|anom'] = np.array(len(r.get('anom', [])))
        out[g + '|post'] = np.array(r['post'], np.float32).reshape(-1, 46, 3)
        if i % 50 == 0:
            print(i, g, n, round(time.time() - t0), 's', flush=True)
    out['__meta'] = np.array(json.dumps(meta))
    out['__errs'] = np.array(json.dumps(errs[:50]))
    b.close()
np.savez_compressed(sal, **out)
print('fin', len(glosas), 'errores pagina', len(errs), round(time.time() - t0), 's')
