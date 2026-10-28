"""Saca la PRIMERA plantilla de cada glosa de plantillas.json (lo que reproduce el avatar) -> primeras.npz"""
import json, sys, numpy as np
ruta = sys.argv[1] if len(sys.argv) > 1 else '../../assets/plantillas.json'
salida = sys.argv[2] if len(sys.argv) > 2 else 'primeras.npz'
d = json.load(open(ruta, encoding='utf-8'))
filas = d['plantillas'] if isinstance(d, dict) else d
vistas = {}
for p in filas:
    g = p.get('gloss')
    if g in vistas: continue
    seq = np.array(p['seq'], dtype=np.float64)
    if seq.shape != (32, 152) or not np.isfinite(seq).all(): continue
    vistas[g] = seq
np.savez_compressed(salida, **vistas)
print(len(vistas), 'glosas ->', salida)
