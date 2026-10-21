#!/usr/bin/env python3
"""Aplica las 12 letras corregidas del alfabeto (K, L, LL, M, NN, O, P, Q, R, RR, S, Z)
a univoz/assets/plantillas.json.

Cada letra nueva se INSERTA justo antes de la primera plantilla de su glosa, porque el
avatar reproduce la primera plantilla de cada glosa. Las plantillas reales que ya estaban
NO se tocan ni se borran (siguen sirviendo para el reconocimiento). Se puede volver a
correr sin duplicar: antes de insertar quita las plantillas marcadas 'v4-*'.

Antes de escribir se guarda una copia en  <raiz del proyecto>\\_respaldo_antes_de_letras_v4\\.

Uso:
  python aplicar_letras_v4.py [--plantillas RUTA] [--datos RUTA] [--solo-probar]
"""
import argparse, json, os, shutil, sys, time

AQUI = os.path.dirname(os.path.abspath(__file__))
POR_DEFECTO = r'D:\UNIVOZ_APK\univoz\assets\plantillas.json'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--plantillas', default=POR_DEFECTO)
    ap.add_argument('--datos', default=os.path.join(AQUI, 'letras_lsm_v4.json'))
    ap.add_argument('--solo-probar', action='store_true', help='no escribe nada, solo informa')
    a = ap.parse_args()

    if not os.path.isfile(a.plantillas):
        sys.exit(f'No encuentro {a.plantillas}')
    if not os.path.isfile(a.datos):
        sys.exit(f'No encuentro {a.datos}')

    print(f'Leyendo {a.plantillas} ({os.path.getsize(a.plantillas) / 1e6:.1f} MB)...')
    with open(a.plantillas, encoding='utf-8') as f:
        d = json.load(f)
    with open(a.datos, encoding='utf-8') as f:
        nuevos = json.load(f)
    if d.get('norm_version') != nuevos.get('norm_version'):
        sys.exit(f"norm_version distinta: {d.get('norm_version')} vs {nuevos.get('norm_version')}")

    P = d['plantillas']
    antes = len(P)
    P = [p for p in P if not str(p.get('sintetica', '')).startswith('v4-')]
    quitadas = antes - len(P)

    insertadas = []
    for gloss, seq in nuevos['glosas'].items():
        if len(seq) != d.get('t_frames', 32) or any(len(fr) != d.get('frame_dim', 152) for fr in seq):
            sys.exit(f'{gloss}: tamano de secuencia incorrecto')
        idx = next((i for i, p in enumerate(P) if p['gloss'] == gloss), None)
        if idx is None:
            print(f'  aviso: {gloss} no existe en el diccionario, se omite')
            continue
        molde = P[idx]
        nueva = {
            'sign_id': molde['sign_id'],
            'gloss': gloss,
            'espanol': molde.get('espanol', gloss),
            'seq': seq,
            'aspecto': 1.0,
            'sintetica': f'v4-{gloss}',
        }
        P.insert(idx, nueva)
        insertadas.append(gloss)

    d['plantillas'] = P
    d['n_plantillas'] = len(P)
    if 'n_exportadas' in d:
        d['n_exportadas'] = d['n_exportadas'] + len(insertadas) - quitadas
    print(f'Quitadas v4 anteriores: {quitadas}. Insertadas: {len(insertadas)} -> {" ".join(insertadas)}')
    print(f'Plantillas: {antes} -> {len(P)}')

    if a.solo_probar:
        print('Solo probar: no se escribio nada.')
        return

    raiz = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(a.plantillas))))
    resp = os.path.join(raiz, '_respaldo_antes_de_letras_v4')
    os.makedirs(resp, exist_ok=True)
    copia = os.path.join(resp, 'plantillas.json')
    if os.path.exists(copia):  # ya hay un respaldo de una corrida anterior: se conserva el primero
        copia = os.path.join(resp, f'plantillas.{time.strftime("%Y%m%d_%H%M%S")}.json')
    shutil.copy2(a.plantillas, copia)
    print(f'Respaldo: {copia}')

    tmp = a.plantillas + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False)
    # comprobar que el archivo nuevo se lee bien antes de reemplazar el bueno
    with open(tmp, encoding='utf-8') as f:
        chk = json.load(f)
    assert chk['n_plantillas'] == len(chk['plantillas']) == len(P)
    os.replace(tmp, a.plantillas)
    print(f'Listo: {a.plantillas} ({os.path.getsize(a.plantillas) / 1e6:.1f} MB)')
    print('Ahora corre la app completa (flutter run), no solo hot reload: los assets se leen al arrancar.')


if __name__ == '__main__':
    main()
