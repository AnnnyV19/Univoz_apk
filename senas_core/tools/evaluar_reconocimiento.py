"""Evaluacion offline del reconocimiento: leave-one-out sobre plantillas.json.

Cada plantilla real de una sena con 2 o mas grabaciones distintas se usa como
consulta; el diccionario es todo lo demas (con espejos, como en la app) SIN la
consulta ni su grupo de equivalencia (copias y gemelas espejo de la misma
grabacion; sin esto el top-1 sale inflado ~27 puntos, ver grupos_equivalentes).
Mide top-1, top-5 (por glosa), aceptada-correcta y
aceptada-erronea con los umbrales del clasificador (0.50 / 0.32).

Limites que conviene tener presentes:
  * plantillas.json ya esta normalizado a 32x152, asi que aqui solo se pueden
    probar filtros que actuan sobre ese espacio (suavizado, picos). Recorte de
    cabeza o relleno de huecos sobre frames crudos necesitan landmarks crudos
    etiquetados, que el repo no tiene.
  * Con --ruido se degrada la consulta para simular una captura sucia; el
    resultado depende de ese modelo de ruido (es una suposicion, no una
    medicion de la camara).
  * 1-3 grabaciones por sena: juzgar por top-1/top-5, no por tasa de aceptacion.

Uso:
  python3 evaluar_reconocimiento.py --salida base.json
  python3 evaluar_reconocimiento.py --ruido mixto --filtro suavizar3 --salida f.json
  python3 evaluar_reconocimiento.py --comparar base.json f.json
"""

import argparse
import json
import multiprocessing as mp
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import dtw  # noqa: E402
import limpieza_sena  # noqa: E402
from sign_norm import mirror_sequence  # noqa: E402

RUTA_PLANTILLAS = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..', 'assets', 'plantillas.json')

# Dimensiones continuas del frame de 152 (ver sign_norm.py): ubicacion de cada
# mano (24-29) y forma de cada mano (32-151). Cuerpo (0-23) y presencia
# (30-31) no se tocan.
DIMS_CONTINUAS = tuple(range(24, 30)) + tuple(range(32, 152))


# --- filtros sobre la consulta (secuencia de frames) -------------------------

def filtro_ninguno(seq):
    return seq


def filtro_suavizar3(seq):
    """Media movil de 3 frames sobre las dims continuas. Solo comprueba que la
    comparacion A/B funciona; los filtros reales se agregan en la Fase 2."""
    n = len(seq)
    out = [list(f) for f in seq]
    for i in range(n):
        a, b = max(0, i - 1), min(n - 1, i + 1)
        for d in DIMS_CONTINUAS:
            out[i][d] = (seq[a][d] + seq[i][d] + seq[b][d]) / 3.0
    return out


FILTROS = {
    'ninguno': filtro_ninguno,
    'suavizar3': filtro_suavizar3,
}
FILTROS.update(limpieza_sena.CANDIDATOS)


# --- ruido simulado ----------------------------------------------------------

def ruido_jitter(seq, rng, k=1.0, sigma=0.02):
    out = [list(f) for f in seq]
    for f in out:
        for d in DIMS_CONTINUAS:
            f[d] += rng.gauss(0.0, sigma * k)
    return out


def ruido_huecos(seq, rng, k=1.0, frac=0.15):
    """Pierde frames y se rellenan copiando el anterior (lo que hace fillGaps)."""
    out = [list(f) for f in seq]
    for i in range(1, len(out)):
        if rng.random() < min(0.9, frac * k):
            out[i] = list(out[i - 1])
    return out


def ruido_picos(seq, rng, k=1.0, frac=0.06, escala=0.25):
    out = [list(f) for f in seq]
    for f in out:
        if rng.random() < min(0.9, frac * k):
            for d in DIMS_CONTINUAS:
                f[d] += rng.uniform(-escala, escala)
    return out


def ruido_mixto(seq, rng, k=1.0):
    return ruido_picos(ruido_huecos(ruido_jitter(seq, rng, k), rng, k), rng, k)


RUIDOS = {
    'ninguno': lambda seq, rng, k=1.0: seq,
    'jitter': ruido_jitter,
    'huecos': ruido_huecos,
    'picos': ruido_picos,
    'mixto': ruido_mixto,
}


# --- datos -------------------------------------------------------------------

_CLF = None
_OPTS = None
_DUENO = {}
_GRUPOS = {}


def cargar(ruta):
    with open(ruta, encoding='utf-8') as f:
        return json.load(f)['plantillas']


def construir(plantillas):
    """Clasificador con todas las plantillas y sus espejos. Template usa
    __slots__, asi que el indice de la plantilla original (para excluirla) se
    guarda aparte en _DUENO, por id del Template."""
    clf = dtw.DtwClassifier()
    _DUENO.clear()
    for i, p in enumerate(plantillas):
        clf.add(p['sign_id'], p['gloss'], p['seq'], p.get('espanol', ''))
        _DUENO[id(clf.templates[-1])] = i
        clf.add(p['sign_id'], p['gloss'], mirror_sequence(p['seq']),
                p.get('espanol', ''))
        _DUENO[id(clf.templates[-1])] = i
    return clf


EPS_EQUIVALENTE = 0.02


def _maxdif(a, b):
    return max(abs(x - y) for fa, fb in zip(a, b) for x, y in zip(fa, fb))


def grupos_equivalentes(plantillas):
    """Para cada plantilla, las de su misma glosa que son la misma grabacion:
    iguales, o espejo una de la otra (max |dif| < EPS_EQUIVALENTE). El
    diccionario guarda muchas senas como par izquierda/derecha y la app suma
    ademas el espejo de cada plantilla; si la gemela espejo de la consulta se
    queda en el diccionario, su espejo reconstruye la consulta (d1 = 0) y el
    top-1 sale inflado."""
    por_glosa = {}
    for i, p in enumerate(plantillas):
        por_glosa.setdefault(p['gloss'], []).append(i)
    espejos = [mirror_sequence(p['seq']) for p in plantillas]
    grupos = {i: {i} for i in range(len(plantillas))}
    for idx in por_glosa.values():
        for a in idx:
            for b in idx:
                if a < b and (
                        _maxdif(plantillas[a]['seq'], plantillas[b]['seq']) < EPS_EQUIVALENTE
                        or _maxdif(plantillas[a]['seq'], espejos[b]) < EPS_EQUIVALENTE):
                    grupos[a].add(b)
                    grupos[b].add(a)
    return grupos


def indices_consulta(plantillas):
    reales = {}
    for i, p in enumerate(plantillas):
        if not p.get('sintetica'):
            reales.setdefault(p['gloss'], []).append(i)
    return sorted(i for v in reales.values() if len(v) >= 2 for i in v)


def evaluar_una(i):
    plantillas, filtro, ruido, semilla, k = _OPTS
    p = plantillas[i]
    rng = random.Random(f'{semilla}:{i}')
    seq = RUIDOS[ruido](p['seq'], rng, k)
    seq = FILTROS[filtro](seq)

    todas = _CLF.templates
    fuera = _GRUPOS[i]
    _CLF.templates = [t for t in todas if _DUENO[id(t)] not in fuera]
    try:
        r = _CLF.rank(seq)
    finally:
        _CLF.templates = todas

    glosas = []
    for _, t in r:
        if t.gloss not in glosas:
            glosas.append(t.gloss)
            if len(glosas) == 5:
                break
    pred = None
    if r:
        d1, t1 = r[0]
        d2 = next((d for d, t in r if t.gloss != t1.gloss), None)
        margen = 1.0 if d2 is None or d2 == 0 else (d2 - d1) / d2
        pred = (t1.gloss, d1, margen)
    gold = p['gloss']
    if pred is None:
        return {'i': i, 'gloss': gold, 'top1': False, 'top5': False,
                'aceptada': False, 'd1': None, 'margen': None}
    g1, d1, margen = pred
    aceptada = d1 <= _CLF.max_distance and margen >= _CLF.min_margin
    return {'i': i, 'gloss': gold, 'pred': g1, 'top1': g1 == gold,
            'top5': gold in glosas, 'aceptada': aceptada,
            'd1': round(d1, 4), 'margen': round(margen, 4)}


def resumen(filas):
    n = len(filas)
    if n == 0:
        return {'n': 0}
    top1 = sum(f['top1'] for f in filas)
    top5 = sum(f['top5'] for f in filas)
    ok = sum(f['aceptada'] and f['top1'] for f in filas)
    mal = sum(f['aceptada'] and not f['top1'] for f in filas)
    return {'n': n, 'top1': top1 / n, 'top5': top5 / n,
            'aceptada_correcta': ok / n, 'aceptada_erronea': mal / n}


def imprimir(res, titulo):
    print(f'{titulo}: n={res["n"]}  top1={res["top1"]:.1%}  top5={res["top5"]:.1%}  '
          f'acept.correcta={res["aceptada_correcta"]:.1%}  '
          f'acept.erronea={res["aceptada_erronea"]:.1%}')


def barrido_margen(filas, max_distance, margenes):
    """Aceptada correcta/erronea para otros umbrales, con las d1/margen ya
    medidas (no repite el DTW). Valido para margenes <= 0.32: con el factor de
    abandono fijo (1.5) el margen de una consulta es exacto hasta 0.333."""
    print(f'barrido de margen minimo (max_distance={max_distance:g}):')
    for m in margenes:
        acept = [f for f in filas if f['d1'] is not None
                 and f['d1'] <= max_distance and f['margen'] >= m]
        ok = sum(f['top1'] for f in acept)
        mal = len(acept) - ok
        n = len(filas)
        print(f'  min_margin={m:.2f}  acept.correcta={ok / n:.1%}  '
              f'acept.erronea={mal / n:.1%}  '
              f'(de las aceptadas, {mal / max(1, len(acept)):.1%} erroneas)')


def correr(args):
    global _CLF, _OPTS, _GRUPOS
    plantillas = cargar(args.plantillas)
    _CLF = construir(plantillas)
    _GRUPOS = grupos_equivalentes(plantillas)
    idx = indices_consulta(plantillas)
    # Una consulta necesita al menos otra grabacion DISTINTA de su glosa.
    idx = [i for i in idx if any(
        plantillas[j]['gloss'] == plantillas[i]['gloss'] and j not in _GRUPOS[i]
        for j in range(len(plantillas)))]
    if args.max_consultas and args.max_consultas < len(idx):
        idx = random.Random(args.semilla).sample(idx, args.max_consultas)
        idx.sort()
    _OPTS = (plantillas, args.filtro, args.ruido, args.semilla, args.intensidad)

    t0 = time.time()
    with mp.get_context('fork').Pool(args.jobs) as pool:
        filas = list(pool.imap_unordered(evaluar_una, idx, chunksize=4))
    filas.sort(key=lambda f: f['i'])
    res = resumen(filas)
    res['segundos'] = round(time.time() - t0, 1)
    meta = {'filtro': args.filtro, 'ruido': args.ruido, 'intensidad': args.intensidad, 'semilla': args.semilla,
            'max_distance': _CLF.max_distance, 'min_margin': _CLF.min_margin,
            'n_plantillas': len(plantillas)}
    imprimir(res, f'filtro={args.filtro} ruido={args.ruido}x{args.intensidad:g}')
    print(f'({res["segundos"]} s, {args.jobs} procesos)')
    if args.barrido_margen:
        barrido_margen(filas, _CLF.max_distance, args.barrido_margen)
    if args.salida:
        with open(args.salida, 'w', encoding='utf-8') as f:
            json.dump({'meta': meta, 'resumen': res, 'consultas': filas}, f)
        print(f'guardado: {args.salida}')


def comparar(a, b):
    with open(a, encoding='utf-8') as f:
        A = json.load(f)
    with open(b, encoding='utf-8') as f:
        B = json.load(f)
    ma, mb = A['meta'], B['meta']
    if (ma['semilla'], ma['ruido'], ma.get('intensidad')) != (mb['semilla'], mb['ruido'], mb.get('intensidad')):
        print('AVISO: semilla, ruido o intensidad distintos; la comparacion pareada no es valida.')
    ra = {c['i']: c for c in A['consultas']}
    rb = {c['i']: c for c in B['consultas']}
    comunes = sorted(set(ra) & set(rb))
    imprimir(resumen([ra[i] for i in comunes]), f'A ({ma["filtro"]}, ruido={ma["ruido"]})')
    imprimir(resumen([rb[i] for i in comunes]), f'B ({mb["filtro"]}, ruido={mb["ruido"]})')
    for campo in ('top1', 'top5'):
        gana = sum(1 for i in comunes if rb[i][campo] and not ra[i][campo])
        pierde = sum(1 for i in comunes if ra[i][campo] and not rb[i][campo])
        print(f'{campo}: B gana {gana}, B pierde {pierde} (neto {gana - pierde:+d} de {len(comunes)})')
    ew_a = sum(1 for i in comunes if ra[i]['aceptada'] and not ra[i]['top1'])
    ew_b = sum(1 for i in comunes if rb[i]['aceptada'] and not rb[i]['top1'])
    print(f'aceptadas erroneas: A={ew_a}  B={ew_b}')


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--plantillas', default=RUTA_PLANTILLAS)
    ap.add_argument('--filtro', choices=sorted(FILTROS), default='ninguno')
    ap.add_argument('--ruido', choices=sorted(RUIDOS), default='ninguno')
    ap.add_argument('--intensidad', type=float, default=1.0,
                    help='multiplica el ruido simulado (1 = nominal)')
    ap.add_argument('--semilla', type=int, default=1)
    ap.add_argument('--max-consultas', type=int, default=0,
                    help='submuestra aleatoria (0 = todas)')
    ap.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) - 2))
    ap.add_argument('--barrido-margen', type=float, nargs='+', metavar='M',
                    help='ademas, aceptada correcta/erronea con estos min_margin '
                         '(<= 0.32), sin repetir el DTW')
    ap.add_argument('--salida', help='JSON con el detalle por consulta')
    ap.add_argument('--comparar', nargs=2, metavar=('A', 'B'))
    args = ap.parse_args()
    if args.comparar:
        comparar(*args.comparar)
    else:
        correr(args)


if __name__ == '__main__':
    main()
