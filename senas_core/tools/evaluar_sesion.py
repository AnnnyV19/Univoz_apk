"""Evalua una sesion real (SessionLogV1, .jsonl) como lo haria Traducir.

Repite sobre los frames fusionados de la sesion (`vec`, 152-d ya normalizado):
  1. el detector de arranque/corte (MovimientoTipoVisor + DetectorAutomatico de
     senas_core/lib/controlador_captura.dart),
  2. la captura (pre-roll, cola), fill_gaps -> resample(32) -> isotropizar,
  3. el DTW contra assets/plantillas.json (tools/dtw.py).
Con --etiquetas (una glosa por linea, en el orden en que se hicieron las senas,
o separadas por comas) mide top-1/top-5 por captura REAL. Sin etiquetas solo
reporta estructura (huecos de mano, picos) y la prediccion de cada captura.

Los parametros del detector son los de la app (skeleton_painter.dart); se
pueden cambiar para comparar variantes sobre la misma sesion.

Uso:
  python3 evaluar_sesion.py ~/Descargas/<sesion>.jsonl
  python3 evaluar_sesion.py <sesion>.jsonl --inicio-ms 0 --con-cuerpo   # app vieja
  python3 evaluar_sesion.py <sesion>.jsonl --etiquetas senas.txt
"""

import argparse
import json
import math
import os
import statistics as st
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import dtw  # noqa: E402
from sign_norm import (fill_gaps, isotropizar_secuencia, mirror_sequence,  # noqa: E402
                       resample)

OL, PL, PR, SL, SR = 24, 30, 31, 32, 92
RUTA_PLANTILLAS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               '..', 'assets', 'plantillas.json')


def _clip(x):
    return 0.0 if x < 0 else 1.0 if x > 1 else x


def leer(ruta):
    frames, eventos = [], []
    with open(ruta, encoding='utf-8') as f:
        for linea in f:
            try:
                j = json.loads(linea)
            except ValueError:
                continue
            if j.get('kind') == 'frame':
                frames.append(j)
            elif j.get('kind') == 'event' and j.get('type') == 'reconocimiento':
                eventos.append(j)
    return frames, eventos


def movimiento(frames, con_cuerpo, intervalo=33):
    """Espejo de MovimientoTipoVisor.alFrame: lista de (indice, hay_movimiento).
    Solo los frames con vec; los saltados por ritmo no aparecen."""
    ant = None
    ant_ms = None
    mano = [None, None]
    mano_ms = [None, None]
    salida = []
    for i, f in enumerate(frames):
        if not f.get('vec'):
            continue
        v = [x if x is not None else 0.0 for x in f['vec']]
        t = f['t']
        if ant_ms is not None and 0 <= t - ant_ms < intervalo:
            continue
        cuerpo = muneca = forma = 0.0
        k = None
        if ant is not None:
            k = intervalo / min(200, max(10, t - ant_ms))
            cuerpo = sum(((v[j] - ant[j]) * k) ** 2 for j in range(OL))
        tenia_ant = ant is not None
        ant, ant_ms = v, t
        con_mano = False
        for lado, (p, l, sh) in enumerate(((PL, OL, SL), (PR, OL + 3, SR))):
            if v[p] < .5:
                continue
            con_mano = True
            act = v[l:l + 3] + v[sh:sh + 60]
            prev, prev_ms = mano[lado], mano_ms[lado]
            mano[lado], mano_ms[lado] = act, t
            if prev is None:
                continue
            dt = t - prev_ms
            if dt <= 0 or dt > 250:
                continue
            kk = intervalo / min(200, max(10, dt))
            muneca += sum(((act[j] - prev[j]) * kk) ** 2 for j in range(3))
            forma += sum(((act[j] - prev[j]) * kk) ** 2 for j in range(3, 63))
        if not tenia_ant:
            salida.append((i, False))
            continue
        pun = max(_clip(math.sqrt(cuerpo) / .08) if con_cuerpo else 0.0,
                  _clip(math.sqrt(muneca) / .06))
        ded = _clip(math.sqrt(forma) / .08)
        salida.append((i, con_mano and (pun >= .8 or ded >= .8)))
    return salida


def capturas(frames, movs, ms_inicio, quietos_cortar, pre_ms, cola_ms,
             min_frames=8):
    """Espejo de DetectorAutomatico (via alimentarMovimiento) + ControladorCaptura:
    lista de (i_ini, i_fin) sobre `frames`."""
    estado = 'q'
    quieto_ms = 0.0
    racha = None
    ultimo_mov_ms = None
    ant_ms = None
    ini_t = None
    pausa_hasta = None
    out = []
    for i, hay in movs:
        t = frames[i]['t']
        # Tras cada captura la app pausa (skeleton_painter.dart:664,675): 300 ms
        # si fue muy corta, 900 ms si se reconocio. Sin eso el replay parte
        # una seña en dos.
        if pausa_hasta is not None:
            if t < pausa_hasta:
                ant_ms = None
                continue
            pausa_hasta = None
            racha = None
        dt = 100.0 if ant_ms is None else float(min(200, max(10, t - ant_ms)))
        ant_ms = t
        if hay and estado == 'q':
            ultimo_mov_ms = t
        elif hay and estado == 'g':
            ultimo_mov_ms = t
        if estado == 'q':
            if not hay:
                racha = None
            else:
                racha = t if racha is None else racha
                if t - racha >= ms_inicio:
                    estado, quieto_ms, racha, ini_t = 'g', 0.0, None, t
        else:
            if hay:
                quieto_ms = 0.0
            else:
                quieto_ms += dt
                if quieto_ms >= (quietos_cortar - .5) * (1000 / 30):
                    hasta = ultimo_mov_ms + cola_ms
                    sel = [j for j, f in enumerate(frames)
                           if ini_t - pre_ms <= f['t'] <= hasta]
                    if sel:
                        out.append((sel[0], sel[-1]))
                    validos = sum(1 for j in sel if frames[j].get('vec'))
                    pausa_hasta = t + (300 if validos < min_frames else 950)
                    estado = 'q'
    return out


def estructura(frames, a, b):
    ventana = frames[a:b + 1]
    validos = [f for f in ventana if f.get('vec')]
    n = len(ventana)
    pres_l = sum(1 for f in validos if f['vec'][PL] >= .5)
    pres_r = sum(1 for f in validos if f['vec'][PR] >= .5)
    con_mano = sum(1 for f in validos if f['vec'][PL] >= .5 or f['vec'][PR] >= .5)
    # rachas de hueco (sin ninguna mano) y picos de velocidad de ubicacion/forma
    huecos, racha = [], 0
    for f in ventana:
        v = f.get('vec')
        if v and (v[PL] >= .5 or v[PR] >= .5):
            if racha:
                huecos.append(racha)
            racha = 0
        else:
            racha += 1
    if racha:
        huecos.append(racha)
    vel = []
    for f0, f1 in zip(validos, validos[1:]):
        for p, sh in ((PL, SL), (PR, SR)):
            if f0['vec'][p] >= .5 and f1['vec'][p] >= .5:
                vel.append(math.sqrt(sum((f1['vec'][j] - f0['vec'][j]) ** 2
                                         for j in range(sh, sh + 60))))
    return {
        'n': n, 'validos': len(validos), 'con_mano': con_mano,
        'L': pres_l, 'R': pres_r,
        'hueco_max': max(huecos) if huecos else 0,
        'vel_forma_p95': sorted(vel)[int(.95 * (len(vel) - 1))] if vel else 0.0,
        'vel_forma_max': max(vel) if vel else 0.0,
    }


def secuencia(frames, a, b):
    ventana = frames[a:b + 1]
    vect = [[x if x is not None else 0.0 for x in f['vec']] if f.get('vec') else None
            for f in ventana]
    lleno = fill_gaps(vect)
    if lleno is None:
        return None
    asp = [f.get('aspect') for f in ventana if f.get('aspect')]
    seq = resample(lleno, 32)
    return isotropizar_secuencia(seq, st.median(asp) if asp else 0.75)


def clasificador():
    with open(RUTA_PLANTILLAS, encoding='utf-8') as f:
        plantillas = json.load(f)['plantillas']
    clf = dtw.DtwClassifier()
    for p in plantillas:
        clf.add(p['sign_id'], p['gloss'], p['seq'], p.get('espanol', ''))
        clf.add(p['sign_id'], p['gloss'], mirror_sequence(p['seq']), p.get('espanol', ''))
    return clf


def glosas_top(rank, n=5):
    out = []
    for d, t in rank:
        if t.gloss not in [g for g, _ in out]:
            out.append((t.gloss, d))
            if len(out) == n:
                break
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('sesion')
    ap.add_argument('--inicio-ms', type=int, default=100,
                    help='movimiento sostenido para arrancar (app nueva: 100; vieja: 0)')
    ap.add_argument('--con-cuerpo', action='store_true',
                    help='el cuerpo cuenta como movimiento (app vieja)')
    ap.add_argument("--quietos", type=int, default=20, help='framesQuietosParaCortar')
    ap.add_argument('--preroll', type=int, default=200)
    ap.add_argument('--cola', type=int, default=100)
    ap.add_argument('--min-frames', type=int, default=8,
                    help='minFramesParaReconocer (frames validos)')
    ap.add_argument('--etiquetas', help='glosas esperadas en orden (una por linea o con comas)')
    args = ap.parse_args()

    frames, eventos = leer(os.path.expanduser(args.sesion))
    movs = movimiento(frames, args.con_cuerpo)
    caps = capturas(frames, movs, args.inicio_ms, args.quietos, args.preroll, args.cola,
                    args.min_frames)
    clf = clasificador()

    etiquetas = None
    if args.etiquetas:
        txt = open(os.path.expanduser(args.etiquetas), encoding='utf-8').read()
        etiquetas = [x.strip().upper() for x in txt.replace(',', '\n').splitlines()
                     if x.strip()]

    print(f'frames={len(frames)} reconocimientos de la app={len(eventos)} '
          f'capturas (replay)={len(caps)}  inicio={args.inicio_ms} ms '
          f'cuerpo={"si" if args.con_cuerpo else "no"}')
    print(f'{"t(s)":>6} {"frames":>6} {"val":>4} {"L":>3} {"R":>3} {"hueco":>5} '
          f'{"velP95":>6}  top3')
    t0 = frames[0]['t'] if frames else 0
    filas = []
    for a, b in caps:
        est = estructura(frames, a, b)
        if est['validos'] < args.min_frames:
            top = [('(muy corta)', 0.0)]
        else:
            seq = secuencia(frames, a, b)
            top = glosas_top(clf.rank(seq), 5) if seq else [('(sin frames)', 0.0)]
        filas.append((est, top))
        print(f'{(frames[a]["t"] - t0) / 1000:6.1f} {est["n"]:6d} {est["validos"]:4d} '
              f'{est["L"]:3d} {est["R"]:3d} {est["hueco_max"]:5d} '
              f'{est["vel_forma_p95"]:6.2f}  '
              + ', '.join(f'{g}:{d:.2f}' for g, d in top[:3]))

    reales = [(e, t) for e, t in filas if t[0][0] not in ('(muy corta)', '(sin frames)')]
    print(f'\ncapturas con prediccion: {len(reales)} de {len(filas)}')
    if etiquetas:
        n = min(len(etiquetas), len(reales))
        ok1 = ok5 = 0
        for esperada, (e, top) in zip(etiquetas, reales):
            glosas = [g for g, _ in top]
            ok1 += glosas[0] == esperada
            ok5 += esperada in glosas
        print(f'etiquetas={len(etiquetas)} emparejadas por orden={n}  '
              f'top1={ok1}/{n}  top5={ok5}/{n}  '
              '(el orden se rompe si hay capturas falsas: revisar la tabla)')


if __name__ == '__main__':
    main()
