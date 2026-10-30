"""Evalua una ronda multiseña real (SessionLogV1, .jsonl) de Traducir.

Protocolo: se hace cada seña N veces SEGUIDAS (un bloque) y entre bloques se
deja una pausa larga (>= --pausa segundos, por defecto 8). Los bloques se
reconocen por esas pausas, en el orden de --senas; no hace falta que la app
haya detectado exactamente N capturas por bloque.

Por cada captura toma lo que decidio la app (evento `reconocimiento`: glosa,
distancia, margen, top) y la ventana de frames de la mano para separar:
  * captura mala: pocas manos utilizables en la ventana (--min-cobertura);
  * seña que no coincide: manos bien vistas pero la glosa correcta no gana.
La aceptacion se recalcula con varios min_margin (max_distance de la app).

Uso:
  python3 evaluar_ronda.py <sesion>.jsonl --senas HOLA,GRACIAS,PERDON
"""

import argparse
import collections
import json
import statistics as st
import sys

LAG_FRAMES = 20  # el evento sale tras 20 frames quietos (framesQuietosParaCortar)
MARGENES = (0.32, 0.20, 0.12)


def leer(ruta):
    frames, eventos, inicio = [], [], None
    with open(ruta, encoding='utf-8') as fh:
        for linea in fh:
            d = json.loads(linea)
            if d['kind'] == 'frame':
                frames.append(d)
            elif d['kind'] == 'event' and d.get('type') == 'reconocimiento':
                eventos.append(d)
            elif d['kind'] == 'session_start':
                inicio = d['started_at_ms']
    return frames, eventos, inicio


def bloques(eventos, pausa_ms):
    out, actual = [], []
    for e in eventos:
        if actual and e['t_ms'] - actual[-1]['t_ms'] >= pausa_ms:
            out.append(actual)
            actual = []
        actual.append(e)
    if actual:
        out.append(actual)
    return out


def cobertura(frames, inicio, e):
    """% de frames con mano utilizable en la ventana de la captura."""
    t0 = frames[0]['t']
    te = e['t_ms'] - inicio + t0
    k = max((i for i, f in enumerate(frames) if f['t'] <= te), default=None)
    if k is None:
        return None
    k -= LAG_FRAMES
    w = frames[max(0, k - e['frames'] + 1):k + 1]
    if not w:
        return None
    return 100 * sum(bool((f['hands'] or {}).get('usable')) for f in w) / len(w)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('sesion')
    ap.add_argument('--senas', required=True,
                    help='glosas en el orden en que se hicieron, separadas por coma')
    ap.add_argument('--pausa', type=float, default=8.0)
    ap.add_argument('--min-cobertura', type=float, default=50.0)
    ap.add_argument('--max-distance', type=float, default=0.50)
    args = ap.parse_args()

    orden = [s.strip() for s in args.senas.split(',') if s.strip()]
    frames, eventos, inicio = leer(args.sesion)
    bs = bloques(eventos, args.pausa * 1000)
    print(f'{len(eventos)} capturas en {len(bs)} bloques; se esperaban {len(orden)}')
    if len(bs) != len(orden):
        huecos = sorted(((b['t_ms'] - a['t_ms']) / 1000
                         for a, b in zip(eventos, eventos[1:])), reverse=True)[:len(orden) + 3]
        sys.exit('no coincide el numero de bloques; mayores pausas (s): '
                 + ', '.join(f'{h:.1f}' for h in huecos)
                 + '. Ajusta --pausa o revisa el orden.')

    filas = []
    for gloss, bloque in zip(orden, bs):
        for e in bloque:
            tops = [t['gloss'] for t in e['top']]
            cob = cobertura(frames, inicio, e)
            filas.append({'gold': gloss, 'pred': e['gloss'], 'd': e['distancia'],
                          'm': e['margen'], 'frames': e['frames'], 'cob': cob,
                          'top1': e['gloss'] == gloss, 'topk': gloss in tops,
                          'acept_app': e['aceptada']})

    print(f'\n{"seña":<14}{"n":>3} {"top1":>5} {"top4":>5} {"cob%":>5}  '
          + '  '.join(f'ok/mal@{m:.2f}' for m in MARGENES) + '   app ok/mal')
    for gloss in orden:
        fs = [f for f in filas if f['gold'] == gloss]
        cobs = [f['cob'] for f in fs if f['cob'] is not None]
        celdas = []
        for m in MARGENES:
            a = [f for f in fs if f['d'] <= args.max_distance and f['m'] >= m]
            ok = sum(f['top1'] for f in a)
            celdas.append(f'{ok:>3}/{len(a) - ok:<3}    ')
        app_ok = sum(f['acept_app'] and f['top1'] for f in fs)
        app_mal = sum(f['acept_app'] and not f['top1'] for f in fs)
        print(f'{gloss:<14}{len(fs):>3} {sum(f["top1"] for f in fs) / len(fs):>5.0%} '
              f'{sum(f["topk"] for f in fs) / len(fs):>5.0%} '
              f'{st.mean(cobs) if cobs else 0:>5.0f}  ' + ' '.join(celdas)
              + f'   {app_ok}/{app_mal}')

    n = len(filas)
    print(f'\nTOTAL n={n} top1={sum(f["top1"] for f in filas) / n:.0%} '
          f'top4={sum(f["topk"] for f in filas) / n:.0%}')

    print('\nFallos (top1 incorrecto):')
    conf = collections.Counter()
    for f in filas:
        if f['top1']:
            continue
        conf[(f['gold'], f['pred'])] += 1
        causa = ('CAPTURA (mano perdida)'
                 if f['cob'] is not None and f['cob'] < args.min_cobertura
                 else 'SEÑA (no coincide con la plantilla)')
        print(f'  {f["gold"]:<12} -> {f["pred"]:<12} d={f["d"]:.2f} m={f["m"]:.2f} '
              f'frames={f["frames"]} cob={f["cob"] if f["cob"] is None else round(f["cob"])}%  {causa}')
    if conf:
        print('\nConfusiones mas frecuentes:')
        for (g, p), c in conf.most_common(8):
            print(f'  {g} -> {p}: {c}')


if __name__ == '__main__':
    main()
