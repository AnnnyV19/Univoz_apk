"""Plantillas con problemas de DATOS (no del avatar): volteos de palma de un cuadro
y angulos de dedo imposibles. uso: datos_malos.py entrada.npz salida.csv"""
import sys, csv, json, numpy as np
exec(open('analizar.py').read().split('filas = []')[0].replace("run = np.load(sys.argv[1]); ent = np.load(sys.argv[2]); pref = sys.argv[3]", "ent=np.load(sys.argv[1]); run={'__meta': json.dumps(dict(der=[-1,0,0], arr=[0,1,0], fre=[0,0,1], ancho=0.217))}"))
LIM = np.array([[100, 120, 95]] * 4)
rows = []
for g in ent.files:
    s = ent[g]
    for lado, c in LADOS.items():
        idx = np.where(s[:, c['pres']] >= 0.5)[0]
        if len(idx) < 3: continue
        P = s[idx, c['shape']:c['shape'] + 60].reshape(-1, 20, 3) @ M_MANO.T
        R = marco_palma(P); cons = np.diff(idx) == 1
        paso = rot_ang(R[:-1], R[1:])[cons]
        volteos = int((paso > 120).sum())
        imp = (flexiones(P)[:, 1:] > LIM).any(axis=(1, 2)).mean()
        if volteos or imp > 0.5:
            rows.append(dict(glosa=g, mano='izquierda' if lado == 'I' else 'derecha',
                             volteos_palma_1_cuadro=volteos, giro_max_grados=round(float(paso.max()) if len(paso) else 0, 0),
                             pct_cuadros_dedos_imposibles=round(100 * float(imp), 0)))
rows.sort(key=lambda r: (-r['volteos_palma_1_cuadro'], -r['pct_cuadros_dedos_imposibles']))
with open(sys.argv[2], 'w', newline='', encoding='utf-8') as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
print('manos-seña con volteo de palma en 1 cuadro (>120°):', sum(r['volteos_palma_1_cuadro'] > 0 for r in rows),
      '| con >50% de cuadros con dedos imposibles:', sum(r['pct_cuadros_dedos_imposibles'] > 50 for r in rows))
print([ (r['glosa'], r['mano'][0], r['volteos_palma_1_cuadro']) for r in rows[:15]])
