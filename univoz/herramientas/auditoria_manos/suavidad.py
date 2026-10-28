"""Entrada (reposo -> seña) y salida (seña -> reposo): velocidad y aceleracion pico de
la muñeca, comparadas con las de la propia seña. uso: suavidad.py run.npz"""
import sys, numpy as np
run = np.load(sys.argv[1]); DT = 1 / 60
L = {'I': (0, 30, 6), 'D': (23, 31, 9)}
ent_v, ent_a, sal_v, sal_a, sena_v = [], [], [], [], []
for g in sorted({k.split('|')[0] for k in run.files if '|' in k}):
    pos = run[g + '|pos']; A = run[g + '|alim']; N = run[g + '|nodos']; P = run[g + '|post']
    for lado, (n0, pres, el) in L.items():
        if not (A[0, pres] >= 0.5 and np.hypot(A[0, el], A[0, el + 1]) > 0.05): continue
        w = N[:, n0 + 2].astype(float)
        v = np.linalg.norm(np.diff(w, axis=0), axis=1) / DT
        a = np.linalg.norm(np.diff(w, 2, axis=0), axis=1) / DT ** 2
        m_ent = np.where(np.arange(len(v)) < 30)[0]          # primeros 0.5 s desde reposo
        ent_v.append(v[m_ent].max()); ent_a.append(a[m_ent[:-1]].max())
        mid = (pos[1:] >= 10) & (pos[1:] <= 28)
        sena_v.append(v[mid].max() if mid.any() else np.nan)
        if A[-1, pres] >= 0.5:
            wp = np.concatenate([w[-1:], P[:, n0 + 2].astype(float)])
            vp = np.linalg.norm(np.diff(wp, axis=0), axis=1) / DT
            ap = np.linalg.norm(np.diff(wp, 2, axis=0), axis=1) / DT ** 2
            sal_v.append(vp.max()); sal_a.append(ap.max())
f = lambda x: 'p50 %.2f  p90 %.2f  max %.2f' % (np.nanmedian(x), np.nanpercentile(x, 90), np.nanmax(x))
print('manos', len(ent_v))
print('entrada  vel pico m/s :', f(ent_v)); print('entrada  acel pico m/s2:', f(ent_a))
print('salida   vel pico m/s :', f(sal_v)); print('salida   acel pico m/s2:', f(sal_a))
print('la seña  vel pico m/s :', f(sena_v))
# Manos que aparecen / se van a media seña
ap_v, ap_a, se_v, se_a = [], [], [], []
for g in sorted({k.split('|')[0] for k in run.files if '|' in k}):
    pos = run[g + '|pos']; A = run[g + '|alim']; N = run[g + '|nodos']
    for lado, (n0, pres, el) in L.items():
        u = (A[:, pres] >= 0.5) & (np.hypot(A[:, el], A[:, el + 1]) > 0.05)
        w = N[:, n0 + 2].astype(float)
        v = np.r_[0, np.linalg.norm(np.diff(w, axis=0), axis=1) / DT]
        a = np.r_[0, 0, np.linalg.norm(np.diff(w, 2, axis=0), axis=1) / DT ** 2]
        for i in np.where(np.diff(u.astype(int)) != 0)[0] + 1:
            if pos[i] <= 1: continue
            ven = slice(i, min(len(v), i + 30))
            (ap_v if u[i] else se_v).append(v[ven].max()); (ap_a if u[i] else se_a).append(a[ven].max())
print('aparece  vel pico m/s :', f(ap_v) if ap_v else '-', ' n', len(ap_v)); print('aparece  acel pico m/s2:', f(ap_a) if ap_a else '-')
print('se va    vel pico m/s :', f(se_v) if se_v else '-', ' n', len(se_v)); print('se va    acel pico m/s2:', f(se_a) if se_a else '-')
