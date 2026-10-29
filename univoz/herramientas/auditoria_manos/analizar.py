"""Compara lo que hizo el avatar (nodos) con lo que se le pidio (frame alimentado)
y con la plantilla original. uso: analizar.py run.npz entrada.npz salida_prefijo"""
import sys, json
import numpy as np

run = np.load(sys.argv[1]); ent = np.load(sys.argv[2]); pref = sys.argv[3]
meta = json.loads(str(run['__meta']))
DER, ARR, FRE = (np.array(meta[k]) for k in ('der', 'arr', 'fre'))
ANCHO = meta['ancho']
M_CUERPO = np.stack([DER, ARR, FRE], 1)      # v_av = M @ v_persona
M_MANO = np.stack([DER, ARR, -FRE], 1)       # forma: z de MediaPipe invertida
LADOS = {'I': dict(n0=0, loc=24, pres=30, shape=32, sh=0, el=2),
         'D': dict(n0=23, loc=27, pres=31, shape=92, sh=3, el=6)}
# hombro D = body[1] -> offset 3; codo I = body[2] -> 6; codo D = body[3] -> 9
LADOS['I'].update(sh=0, el=6); LADOS['D'].update(sh=3, el=9)
DEDOS = {'pulgar': [0, 1, 2, 3], 'indice': [4, 5, 6, 7], 'medio': [8, 9, 10, 11],
         'anular': [12, 13, 14, 15], 'menique': [16, 17, 18, 19]}

def unit(v):
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.maximum(n, 1e-12)

def ang(a, b):
    return np.degrees(np.arccos(np.clip((unit(a) * unit(b)).sum(-1), -1, 1)))

def marco_palma(P):
    """P: (...,20,3) relativo a la muñeca. Devuelve (...,3,3) columnas u,s,n."""
    u = unit(P[..., 8, :])
    s = P[..., 4, :] - P[..., 16, :]
    n = unit(np.cross(u, s))
    s = np.cross(n, u)
    return np.stack([u, s, n], -1)

def flexiones(P):
    """angulos (grados) en cada articulacion: (...,5,3)"""
    W = np.zeros(P.shape[:-2] + (1, 3))
    out = []
    for idx in DEDOS.values():
        pts = np.concatenate([W, P[..., idx, :]], -2)
        seg = np.diff(pts, axis=-2)
        out.append(ang(seg[..., :-1, :], seg[..., 1:, :]))
    return np.stack(out, -2)

def rot_ang(Ra, Rb):
    R = np.einsum('...ji,...jk->...ik', Ra, Rb)
    tr = np.trace(R, axis1=-2, axis2=-1)
    return np.degrees(np.arccos(np.clip((tr - 1) / 2, -1, 1)))

def interp(seq, pos):
    i0 = np.clip(np.floor(pos).astype(int), 0, len(seq) - 1)
    i1 = np.clip(i0 + 1, 0, len(seq) - 1)
    f = (pos - i0)[:, None]
    return seq[i0] * (1 - f) + seq[i1] * f

filas = []
glosas = sorted({k.split('|')[0] for k in run.files if '|' in k})
for g in glosas:
    pos = run[g + '|pos'].astype(float); A = run[g + '|alim'].astype(float)
    N = run[g + '|nodos'].astype(float); orig = interp(ent[g], pos)
    for lado, c in LADOS.items():
        pres = (A[:, c['pres']] >= 0.5) & (np.hypot(A[:, c['el']], A[:, c['el'] + 1]) > 0.05)
        pres &= pos >= 3.0           # fuera la entrada desde reposo
        pres &= orig[:, c['pres']] >= 0.5   # solo donde la plantilla original tiene la mano
        if pres.sum() < 4: continue
        k = np.where(pres)[0]
        n0 = c['n0']
        hom = N[k, n0]; codo = N[k, n0 + 1]; mun = N[k, n0 + 2]
        Pav = N[k, n0 + 3:n0 + 23] - mun[:, None]
        # objetivo (frame alimentado) en el mundo del avatar
        sh_t = A[k, c['sh']:c['sh'] + 3]; el_t = A[k, c['el']:c['el'] + 3]
        wr_t = A[k, c['loc']:c['loc'] + 3]
        obj_mun = hom + ((wr_t - sh_t) @ M_CUERPO.T) * ANCHO
        Pt = A[k, c['shape']:c['shape'] + 60].reshape(-1, 20, 3) @ M_MANO.T
        e_mun = np.linalg.norm(mun - obj_mun, axis=1) * 100
        e_mun_y = (mun - obj_mun)[:, 1] * 100
        e_codo = ang(codo - hom, (el_t - sh_t) @ M_CUERPO.T)
        Ra, Rt = marco_palma(Pav), marco_palma(Pt)
        e_palma = rot_ang(Ra, Rt)
        e_apunta = ang(Ra[..., 0], Rt[..., 0])
        fa, ft = flexiones(Pav), flexiones(Pt)
        e_flex = np.abs(fa - ft)                       # (k,5,3)
        # forma en el marco de la palma, normalizada por largo de mano
        la = np.linalg.norm(Pav[:, 8], axis=1)[:, None, None]
        lt = np.linalg.norm(Pt[:, 8], axis=1)[:, None, None]
        Qa = np.einsum('kij,kpi->kpj', Ra, Pav / la)
        Qt = np.einsum('kij,kpi->kpj', Rt, Pt / lt)
        e_forma = np.linalg.norm(Qa - Qt, axis=2)      # (k,20) en largos de mano
        e_puntas = e_forma[:, [3, 7, 11, 15, 19]].mean(1)
        # saltos: paso a paso del avatar vs del objetivo (ticks consecutivos)
        cons = np.diff(k) == 1
        dm_av = np.linalg.norm(np.diff(mun, axis=0), axis=1)[cons] * 100
        dm_ob = np.linalg.norm(np.diff(obj_mun, axis=0), axis=1)[cons] * 100
        dR_av = rot_ang(Ra[:-1], Ra[1:])[cons]; dR_ob = rot_ang(Rt[:-1], Rt[1:])[cons]
        df_av = np.abs(np.diff(fa, axis=0)).max(axis=(1, 2))[cons]
        df_ob = np.abs(np.diff(ft, axis=0)).max(axis=(1, 2))[cons]
        # alimentado vs plantilla original (limpieza de prepararSecuencia)
        wr_o = orig[k, c['loc']:c['loc'] + 3]
        e_prep = np.linalg.norm(((wr_t - wr_o) @ M_CUERPO.T) * ANCHO, axis=1) * 100
        filas.append(dict(
            glosa=g, lado=lado, n=len(k),
            mun_med=float(np.median(e_mun)), mun_p90=float(np.percentile(e_mun, 90)),
            mun_max=float(e_mun.max()), mun_y_max=float(np.abs(e_mun_y).max()),
            mun_y_med=float(np.median(e_mun_y)),
            codo_med=float(np.median(e_codo)), codo_max=float(e_codo.max()),
            palma_med=float(np.median(e_palma)), palma_p90=float(np.percentile(e_palma, 90)),
            palma_max=float(e_palma.max()), apunta_med=float(np.median(e_apunta)),
            flex_med=float(np.median(e_flex)), flex_p90=float(np.percentile(e_flex, 90)),
            flex_max=float(e_flex.max()),
            flex_por=np.median(e_flex, axis=0).round(1).tolist(),
            flex_signo=np.median(fa - ft, axis=0).round(1).tolist(),
            forma_med=float(np.median(e_forma)), puntas_med=float(np.median(e_puntas)),
            puntas_max=float(e_puntas.max()),
            salto_mun=float((dm_av - dm_ob).max()) if cons.any() else 0.0,
            salto_mun_ratio=float((dm_av / np.maximum(dm_ob, 0.3)).max()) if cons.any() else 0.0,
            salto_palma=float((dR_av - dR_ob).max()) if cons.any() else 0.0,
            salto_dedo=float((df_av - df_ob).max()) if cons.any() else 0.0,
            prep_max=float(e_prep.max()),
        ))
json.dump(filas, open(pref + '_filas.json', 'w'))
def resumen(clave, q=(50, 90, 99, 100)):
    v = np.array([f[clave] for f in filas])
    return ' '.join('p%d=%.2f' % (x, np.percentile(v, x)) for x in q)
print('manos-seña analizadas', len(filas))
for c in ['mun_med', 'mun_p90', 'mun_max', 'mun_y_max', 'mun_y_med', 'codo_med', 'palma_med', 'palma_p90',
          'palma_max', 'apunta_med', 'flex_med', 'flex_p90', 'flex_max', 'forma_med', 'puntas_med',
          'puntas_max', 'salto_mun', 'salto_mun_ratio', 'salto_palma', 'salto_dedo', 'prep_max']:
    print('%-16s %s' % (c, resumen(c)))
F = np.array([f['flex_por'] for f in filas]); S = np.array([f['flex_signo'] for f in filas])
print('error flexion mediano por dedo (MCP,PIP,DIP)  y sesgo (avatar - objetivo):')
for i, d in enumerate(DEDOS):
    print('  %-8s' % d, np.median(F[:, i], 0).round(1), ' sesgo', np.median(S[:, i], 0).round(1))
