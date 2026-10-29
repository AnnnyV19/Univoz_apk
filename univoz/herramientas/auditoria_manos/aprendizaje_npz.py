"""assets/aprendizaje.json (float16 base64) -> aprendizaje_seq.npz para el arnes."""
import json, base64, sys, os, numpy as np
AQUI = os.path.dirname(os.path.abspath(__file__))
ruta = sys.argv[1] if len(sys.argv) > 1 else os.path.join(AQUI, '..', '..', 'assets', 'aprendizaje.json')
d = json.load(open(ruta, encoding='utf-8')); out = {}
for p in d['plantillas']:
    g = p['gloss'].replace('/', '_')
    if g not in out:
        out[g] = np.frombuffer(base64.b64decode(p['seq_f16']), dtype='<f2').astype(np.float64).reshape(32, 152)
np.savez_compressed('aprendizaje_seq.npz', **out); print(len(out), 'señas -> aprendizaje_seq.npz')
