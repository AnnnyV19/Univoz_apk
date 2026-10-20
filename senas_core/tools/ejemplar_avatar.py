#!/usr/bin/env python3
"""Elige, para cada sena, la toma que el avatar debe mostrar (la ejemplar).

El avatar reproduce la PRIMERA plantilla de cada glosa en plantillas.json. Esa primera
toma era arbitraria: en varias senas era un valor atipico (HOLA a la altura de la cadera con
una mano colgando, mientras las otras 24 tomas estan a la altura de la cabeza). Aqui se
escoge la toma "del medio" del grupo (la medoide: la de menor distancia DTW promedio a las
demas), con buena presencia de mano Y con la altura tipica del grupo (la muneca a menos de
ALTURA_TOL anchos de hombro de la mediana de alturas del grupo: la medoide por forma sola
podia caer en una toma mas alta o mas baja que la mayoria, p. ej. COMO_ESTAS), y se agrega
UNA COPIA como primera plantilla de la glosa, marcada  sintetica = "ejemplar-<GLOSA>".

* No se mueve ni normaliza ninguna altura: la copia es la toma real tal cual (regla de Lani).
* Si la toma elegida es de mano izquierda, la copia es su version espejo (zurdo -> diestro,
  con sign_norm.mirror_sequence, la misma que ya usa la app), para que el avatar sea diestro.
* Las tomas originales NO se tocan ni se borran. Se puede correr varias veces (quita antes
  los 'ejemplar-*' anteriores). Respaldo en <raiz>\\_respaldo_antes_de_ejemplar\\.

Uso (desde senas_core\\tools):
  python ejemplar_avatar.py --solo-probar            # solo muestra la tabla
  python ejemplar_avatar.py                          # aplica
  python ejemplar_avatar.py --glosas HOLA,PERDON     # solo esas
  python ejemplar_avatar.py --todas                  # todas las glosas con 3+ tomas (las letras no)
"""
import argparse, json, os, shutil, sys, time

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, AQUI)
from dtw import dtw_distance          # noqa: E402

# Espejo de un frame normalizado (copia de sign_norm.mirror_frame, layout 2.0.0 de 152 dimensiones):
# invierte X y cruza izquierda/derecha. Va aqui para no depender de la version de sign_norm.py.
_MIRROR_PAIRS = [(0, 1), (2, 3), (4, 5), (6, 7)]


def _mirror_frame(v):
    out = [0.0] * 152
    for a, b in _MIRROR_PAIRS:
        for src, dst in ((b, a), (a, b)):
            out[dst * 3] = -v[src * 3]
            out[dst * 3 + 1] = v[src * 3 + 1]
            out[dst * 3 + 2] = v[src * 3 + 2]
    out[24], out[25], out[26] = -v[27], v[28], v[29]
    out[27], out[28], out[29] = -v[24], v[25], v[26]
    out[30], out[31] = v[31], v[30]
    for j in range(20):
        sl, sr = 32 + j * 3, 92 + j * 3
        out[sl], out[sl + 1], out[sl + 2] = -v[sr], v[sr + 1], v[sr + 2]
        out[sr], out[sr + 1], out[sr + 2] = -v[sl], v[sl + 1], v[sl + 2]
    return out


def mirror_sequence(seq):
    return [_mirror_frame(f) for f in seq]

POR_DEFECTO = r'D:\UNIVOZ_APK\univoz\assets\plantillas.json'
FRASES_DEL_CAMINO = ['HOLA', 'ADIOS', 'GRACIAS', 'COMO_ESTAS', 'BIEN', 'PERDON', 'DISCULPA', 'AYUDA',
                     'AYUDAR', 'ME_AYUDAS_UN_POCO', 'SI_PUEDO', 'NO_PUEDO', 'FACIL', 'DIFICIL', 'MI_NOMBRE_ES']
LETRAS = {chr(c) for c in range(65, 91)} | {'LL', 'NN', 'RR'}
PRES_L, PRES_R = 30, 31
LOC_L_Y, LOC_R_Y = 25, 28
MIN_PRESENCIA = 0.8
ALTURA_TOL = 0.2       # anchos de hombro; la toma elegida queda cerca de la altura tipica del grupo


def mano_dominante(seq):
    pl = sum(f[PRES_L] for f in seq) / len(seq)
    pr = sum(f[PRES_R] for f in seq) / len(seq)
    return ('R', pr) if pr >= pl else ('L', pl)


def altura_mediana(seq, mano):
    """Mediana de la altura (y) de la muneca de la mano dominante, solo cuadros con la mano."""
    ip, iy = (PRES_R, LOC_R_Y) if mano == 'R' else (PRES_L, LOC_L_Y)
    ys = sorted(f[iy] for f in seq if f[ip] >= 0.5)
    return ys[len(ys) // 2] if ys else float('nan')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--plantillas', default=POR_DEFECTO)
    ap.add_argument('--glosas', default=','.join(FRASES_DEL_CAMINO))
    ap.add_argument('--todas', action='store_true')
    ap.add_argument('--solo-probar', action='store_true')
    a = ap.parse_args()

    print(f'Leyendo {a.plantillas} ({os.path.getsize(a.plantillas) / 1e6:.1f} MB)...')
    with open(a.plantillas, encoding='utf-8') as f:
        d = json.load(f)
    P = [p for p in d['plantillas'] if not str(p.get('sintetica', '')).startswith('ejemplar-')]
    quitadas = len(d['plantillas']) - len(P)

    reales = {}
    for i, p in enumerate(P):
        if p.get('sintetica'):
            continue
        reales.setdefault(p['gloss'], []).append(i)
    if a.todas:
        glosas = [g for g, ix in reales.items() if len(ix) >= 3 and g not in LETRAS]
    else:
        glosas = [g.strip() for g in a.glosas.split(',') if g.strip()]

    nuevas = []   # (indice de insercion, plantilla)
    print(f'{"glosa":20s} {"tomas":>5s} {"elegida":>7s} {"mano":>4s} {"altura antes -> despues":>26s}  nota')
    for g in glosas:
        ix = reales.get(g, [])
        if not ix:
            print(f'{g:20s}  (no esta en el diccionario)')
            continue
        primera = P[ix[0]]
        h0, _ = mano_dominante(primera['seq'])
        y0 = altura_mediana(primera['seq'], h0)
        info = []
        for i in ix:
            h, pres = mano_dominante(P[i]['seq'])
            seq = P[i]['seq'] if h == 'R' else mirror_sequence(P[i]['seq'])   # todas como diestras
            info.append((i, h, pres, seq))
        buenas = [t for t in info if t[2] >= MIN_PRESENCIA] or info
        alturas = {t[0]: altura_mediana(P[t[0]]['seq'], t[1]) for t in info}
        validas = sorted(a for a in alturas.values() if a == a)
        h_grupo = validas[len(validas) // 2] if validas else float('nan')
        cerca = [t for t in buenas if alturas[t[0]] == alturas[t[0]] and abs(alturas[t[0]] - h_grupo) <= ALTURA_TOL]
        nota = ''
        if cerca and len(cerca) < len(buenas):
            nota = f'{len(buenas) - len(cerca)} toma(s) descartada(s) por altura (grupo {h_grupo:+.2f}) '
            buenas = cerca
        if len(info) < 3:
            # con 1-2 tomas no hay "grupo": se deja la mejor presencia
            elegida = max(buenas, key=lambda t: t[2])
            nota += f'solo {len(info)} toma(s): no hay consenso, hacen falta mas'
        else:
            mejor, mejor_d = None, 1e9
            for t in buenas:
                ds = [dtw_distance(t[3], o[3]) for o in info if o[0] != t[0]]
                m = sum(ds) / len(ds)
                if m < mejor_d:
                    mejor, mejor_d = t, m
            elegida = mejor
        i, h, pres, seq = elegida
        y1 = altura_mediana(P[i]['seq'], h)
        molde = P[ix[0]]
        copia = {
            'sign_id': molde['sign_id'], 'gloss': g, 'espanol': molde.get('espanol', g),
            'seq': [[round(float(x), 5) for x in fr] for fr in seq],
            'aspecto': P[i].get('aspecto', 1.0),
            'sintetica': f'ejemplar-{g}',
        }
        nuevas.append((ix[0], copia))
        cambio = 'igual' if i == ix[0] and h == 'R' else 'CAMBIA'
        print(f'{g:20s} {len(info):5d} {i:7d} {h:>4s} {y0:+10.2f} -> {y1:+6.2f}  {cambio} {nota}')

    print(f'Quitadas "ejemplar-*" anteriores: {quitadas}. Se agregan {len(nuevas)} copias.')
    if a.solo_probar:
        print('Solo probar: no se escribio nada.')
        return

    # insertar de atras hacia adelante para no mover los indices
    for pos, copia in sorted(nuevas, key=lambda t: -t[0]):
        P.insert(pos, copia)
    d['plantillas'] = P
    d['n_plantillas'] = len(P)
    if 'n_exportadas' in d:
        d['n_exportadas'] = d['n_exportadas'] - quitadas + len(nuevas)

    raiz = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(a.plantillas))))
    resp = os.path.join(raiz, '_respaldo_antes_de_ejemplar')
    os.makedirs(resp, exist_ok=True)
    copia_resp = os.path.join(resp, 'plantillas.json')
    if os.path.exists(copia_resp):
        copia_resp = os.path.join(resp, f'plantillas.{time.strftime("%Y%m%d_%H%M%S")}.json')
    shutil.copy2(a.plantillas, copia_resp)
    print(f'Respaldo: {copia_resp}')

    tmp = a.plantillas + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False)
    with open(tmp, encoding='utf-8') as f:
        chk = json.load(f)
    assert chk['n_plantillas'] == len(chk['plantillas']) == len(P)
    os.replace(tmp, a.plantillas)
    print(f'Listo: {a.plantillas} ({os.path.getsize(a.plantillas) / 1e6:.1f} MB)')
    print('Corre la app completa (flutter run): los assets se leen al arrancar.')


if __name__ == '__main__':
    main()
