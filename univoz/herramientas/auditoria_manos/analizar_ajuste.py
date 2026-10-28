"""Error del movimiento independiente de como cada visor ubica el espacio:
por seña y mano se ajusta escala + traslado (muñeca) y una rotacion fija
(palma), y se mide lo que sobra. uso: analizar_ajuste.py run.npz entrada.npz"""
import sys, json
import numpy as np

exec(open('analizar.py').read().split('filas = []')[0].replace(
    "run = np.load(sys.argv[1]); ent = np.load(sys.argv[2]); pref = sys.argv[3]",
    "run = np.load(sys.argv[1]); ent = np.load(sys.argv[2])"))


def rot_media(Rs):
    """Rotacion promedio (proyeccion de la media a SO(3))."""
    U, _, Vt = np.linalg.svd(Rs.mean(0))
    R = U @ Vt
    if np.linalg.det(R) < 0:
        U[:, -1] *= -1
        R = U @ Vt
    return R


res = []
for g in sorted({k.split('|')[0] for k in run.files if '|' in k}):
    pos = run[g + '|pos'].astype(float); A = run[g + '|alim'].astype(float)
    N = run[g + '|nodos'].astype(float); orig = interp(ent[g], np.maximum(pos, 0))
    for lado, c in LADOS.items():
        k = np.where((pos >= 3) & (orig[:, c['pres']] >= 0.5) &
                     (np.hypot(orig[:, c['el']], orig[:, c['el'] + 1]) > 0.05))[0]
        if len(k) < 8: continue
        n0 = c['n0']
        av = N[k, n0 + 2] - N[k, n0]                      # muñeca - hombro (avatar)
        tp = (orig[k, c['loc']:c['loc'] + 3] - orig[k, c['sh']:c['sh'] + 3]) @ M_CUERPO.T
        # escala + traslado por minimos cuadrados
        tc = tp - tp.mean(0); ac = av - av.mean(0)
        s = (tc * ac).sum() / max((tc * tc).sum(), 1e-12)
        r = ac - s * tc
        e_mun = np.linalg.norm(r, axis=1) * 100
        rango = np.linalg.norm(ac, axis=1).max() * 100     # cuanto se mueve la muñeca
        Pav = N[k, n0 + 3:n0 + 23] - N[k, n0 + 2][:, None]
        Pt = orig[k, c['shape']:c['shape'] + 60].reshape(-1, 20, 3) @ M_MANO.T
        Ra, Rt = marco_palma(Pav), marco_palma(Pt)
        D = np.einsum('kij,klj->kil', Ra, Rt)              # Ra Rt^T
        R0 = rot_media(D)
        e_pal = rot_ang(Ra, np.einsum('ij,kjl->kil', R0, Rt))
        da = rot_ang(Ra[:-1], Ra[1:])[np.diff(k) == 1]
        res.append((g, lado, np.median(e_mun), np.percentile(e_mun, 90), e_mun.max(),
                    np.median(e_pal), np.percentile(e_pal, 90), da.max() if len(da) else 0, s, rango))
R = np.array([r[2:] for r in res], float)
print('manos-seña', len(R))
for j, n in enumerate(['muñeca mediana cm', 'muñeca p90 cm', 'muñeca max cm',
                       'palma mediana °', 'palma p90 °', 'giro max palma °/tick', 'escala']):
    v = R[:, j]
    print('%-22s p50 %6.2f  p90 %6.2f  p99 %6.2f' % (n, np.median(v), np.percentile(v, 90), np.percentile(v, 99)))
print('latigazos de palma >30°/tick:', int((R[:, 5] > 30).sum()))
json.dump([[str(x) for x in r[:2]] + [float(y) for y in r[2:]] for r in res],
          open(sys.argv[1].replace('.npz', '_ajuste.json'), 'w'))
