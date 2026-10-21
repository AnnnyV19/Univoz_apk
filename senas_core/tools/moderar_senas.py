#!/usr/bin/env python3
"""Saca de la app las palabras que no queremos ensenar ni reconocer
(Hitler, insultos, groserias...) segun tools/palabras_prohibidas.txt.

Que hace
  - [bloquear]: todas las muestras de esa sena (pendientes o aprobadas) pasan a
    'rechazada'. NO se borra nada: queda un .sql para revertirlo.
  - [revisar]: solo las lista. aprobar_dataset.py no las aprueba mientras sigan
    ahi; para decidir, mueve la palabra a [permitir] o a [bloquear] en el .txt.
  - Si se rechazo algo que ya estaba 'aprobada', plantillas.json (lo que lee la
    app) quedo desactualizado: corre con --exportar para regenerarlo.
  - Se puede correr las veces que quieras (es idempotente) y despues de cada
    importacion nueva: palabras nuevas que coincidan se bloquean igual.

USO (desde senas_core)
    python tools/moderar_senas.py --seco             # solo dice que haria
    python tools/moderar_senas.py                    # rechaza lo de [bloquear]
    python tools/moderar_senas.py --exportar         # ... y regenera plantillas.json
    python tools/moderar_senas.py --probar "Adolf Hitler" casa pedo   # sin tocar la base
    python tools/moderar_senas.py --json D:\\UNIVOZ_APK\\univoz\\assets\\plantillas.json
                                                     # revisa un plantillas.json ya hecho

Deja en datasets_lsm/:
    moderacion_<fecha>.csv                 que se marco y por que
    revertir_moderacion_<fecha>.sql        para devolver cada muestra a su estado anterior
"""

import argparse
import csv
import datetime
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from glosa import a_glosa  # noqa: E402

RAIZ = os.path.abspath(os.path.join(HERE, ".."))                 # senas_core
LISTA_DEFECTO = os.path.join(HERE, "palabras_prohibidas.txt")
DATOS_DEFECTO = os.path.join(RAIZ, "datasets_lsm")
DESTINOS_DEFECTO = [
    r"D:\UNIVOZ_APK\univoz\assets\plantillas.json",      # el que lee la app
    r"D:\UNIVOZ_APK\senas_core\assets\plantillas.json",  # el del paquete
]
RESPALDO_DEFECTO = r"D:\UNIVOZ_APK\_respaldo_antes_de_dataset"


def log(*partes):
    print(*partes, flush=True)


def _consola_tolerante():
    for flujo in (sys.stdout, sys.stderr):
        try:
            flujo.reconfigure(errors="replace")
        except Exception:
            pass


# ---------------------------------------------------------------------------
# La lista
# ---------------------------------------------------------------------------
class Regla:
    __slots__ = ("texto", "partes", "exacta")

    def __init__(self, texto, partes, exacta):
        self.texto = texto        # como la escribiste en el .txt
        self.partes = partes      # [(PALABRA, es_prefijo), ...] ya normalizadas
        self.exacta = exacta      # '=': la glosa entera tiene que ser eso


class Reglas:
    def __init__(self, ruta):
        self.ruta = ruta
        self.bloquear = []
        self.revisar = []
        self.permitir = set()


def cargar_reglas(ruta=LISTA_DEFECTO):
    if not os.path.exists(ruta):
        raise SystemExit(f"no encuentro la lista de palabras: {ruta}\n"
                         "debe estar junto a moderar_senas.py (tools/palabras_prohibidas.txt)")
    reglas = Reglas(ruta)
    seccion = None
    with open(ruta, encoding="utf-8-sig") as f:
        for n, linea in enumerate(f, 1):
            linea = linea.split("#", 1)[0].strip()
            if not linea:
                continue
            if linea.startswith("[") and linea.endswith("]"):
                seccion = linea[1:-1].strip().lower()
                if seccion not in ("bloquear", "revisar", "permitir"):
                    raise SystemExit(f"{ruta}, linea {n}: no conozco la seccion [{seccion}] "
                                     "(las validas son [bloquear], [revisar] y [permitir])")
                continue
            if seccion is None:
                raise SystemExit(f"{ruta}, linea {n}: falta poner antes una seccion, por ejemplo [bloquear]")
            if seccion == "permitir":
                g = a_glosa(linea.lstrip("="))
                if g:
                    reglas.permitir.add(g)
                continue
            exacta = linea.startswith("=")
            texto = linea.lstrip("=").strip()
            partes = []
            for w in texto.replace("_", " ").split():
                prefijo = w.endswith("*")
                nucleo = a_glosa(w.rstrip("*"))
                if nucleo:
                    partes.append((nucleo, prefijo))
            if partes:
                getattr(reglas, seccion).append(Regla(linea, partes, exacta))
    return reglas


def _tokens(texto):
    return [t for t in a_glosa(texto or "").split("_") if t]


def _igual(token, parte):
    nucleo, prefijo = parte
    return token == nucleo or (prefijo and token.startswith(nucleo))


def _coincide(regla, toks):
    n = len(regla.partes)
    if len(toks) < n:
        return False
    if regla.exacta:
        return len(toks) == n and all(_igual(t, p) for t, p in zip(toks, regla.partes))
    for i in range(len(toks) - n + 1):
        if all(_igual(toks[i + j], regla.partes[j]) for j in range(n)):
            return True
    return False


def evaluar(reglas, gloss, espanol=""):
    """None si esta bien; ('bloquear'|'revisar', regla) si coincide con la lista.

    Compara palabras completas, en la glosa y en el texto en espanol."""
    g = a_glosa(gloss or "")
    if g in reglas.permitir:
        return None
    toks = _tokens(gloss)
    toks_e = _tokens(espanol)
    for nivel in ("bloquear", "revisar"):
        for r in getattr(reglas, nivel):
            if _coincide(r, toks) or (toks_e and _coincide(r, toks_e)):
                return nivel, r.texto
    return None


# ---------------------------------------------------------------------------
# La base
# ---------------------------------------------------------------------------
def _n(x):
    return int(x) if x is not None else 0


def _trozos(lista, tam):
    for i in range(0, len(lista), tam):
        yield lista[i:i + tam]


def conectar():
    from dotenv import load_dotenv
    load_dotenv()
    import db
    return db.conectar()


def clasificar_base(conn, reglas):
    """Todas las senas de la base, con lo que dice la lista.
    Devuelve (bloqueadas, por_revisar): listas de dicts."""
    cur = conn.cursor()
    cur.execute(
        """SELECT s.id, s.gloss, s.espanol,
                  count(ss.id) FILTER (WHERE ss.estado = 'pendiente'),
                  count(ss.id) FILTER (WHERE ss.estado = 'aprobada'),
                  count(ss.id) FILTER (WHERE ss.estado = 'rechazada')
           FROM signs s LEFT JOIN sign_samples ss ON ss.sign_id = s.id
           GROUP BY s.id, s.gloss, s.espanol
           ORDER BY s.gloss""")
    bloqueadas, por_revisar = [], []
    total = 0
    for sid, gloss, espanol, pend, apro, rech in cur.fetchall():
        total += 1
        v = evaluar(reglas, gloss, espanol)
        if not v:
            continue
        fila = {"id": str(sid), "gloss": gloss, "espanol": espanol or "", "regla": v[1],
                "pendientes": _n(pend), "aprobadas": _n(apro), "rechazadas": _n(rech)}
        (bloqueadas if v[0] == "bloquear" else por_revisar).append(fila)
    return bloqueadas, por_revisar, total


def rechazar(conn, bloqueadas, seco=False, carpeta=DATOS_DEFECTO, estampa=None):
    """Pasa a 'rechazada' lo que siga pendiente/aprobado de las senas bloqueadas.
    Devuelve (muestras_cambiadas, de_esas_eran_aprobadas, ruta_sql_o_None)."""
    ids = [b["id"] for b in bloqueadas if b["pendientes"] or b["aprobadas"]]
    if not ids:
        return 0, 0, None
    cur = conn.cursor()
    previas = {}                       # id de muestra -> estado que tenia
    for tr in _trozos(ids, 400):
        cur.execute("SELECT id, estado FROM sign_samples "
                    "WHERE sign_id = ANY(%s::uuid[]) AND estado <> 'rechazada'", (tr,))
        for mid, est in cur.fetchall():
            previas[str(mid)] = est
    if not previas:
        return 0, 0, None
    aprobadas = sum(1 for e in previas.values() if e == "aprobada")
    if seco:
        return len(previas), aprobadas, None

    estampa = estampa or datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    os.makedirs(carpeta, exist_ok=True)
    ruta = os.path.join(carpeta, f"revertir_moderacion_{estampa}.sql")
    # El .sql se escribe ANTES de tocar la base: si algo falla a medias, igual queda el camino de vuelta.
    with open(ruta, "w", encoding="utf-8") as f:
        f.write(f"-- Revierte la moderacion del {estampa}: cada muestra vuelve al estado que tenia.\n"
                "-- Antes de correrlo, saca esas palabras de [bloquear] en tools/palabras_prohibidas.txt\n"
                "-- (o ponlas en [permitir]); si no, la siguiente moderacion las vuelve a rechazar.\n"
                "-- Despues: python tools/moderar_senas.py --exportar   (o exportar_paquete.py)\n\n")
        for estado in ("aprobada", "pendiente"):
            de_estado = sorted(i for i, e in previas.items() if e == estado)
            if not de_estado:
                continue
            f.write(f"UPDATE sign_samples SET estado = '{estado}'\nWHERE id IN (\n  "
                    + ",\n  ".join(f"'{i}'" for i in de_estado) + "\n);\n\n")
    todos = sorted(previas)
    try:
        for tr in _trozos(todos, 400):
            cur.execute("UPDATE sign_samples SET estado = 'rechazada' "
                        "WHERE id = ANY(%s::uuid[]) AND estado <> 'rechazada'", (tr,))
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    return len(previas), aprobadas, ruta


def retener(conn, por_revisar, seco=False, carpeta=DATOS_DEFECTO, estampa=None):
    """Las muestras APROBADAS de las senas [revisar] vuelven a 'pendiente' (en espera de que
    decidas). Devuelve (cuantas, ruta_sql_o_None)."""
    ids = [b["id"] for b in por_revisar if b["aprobadas"]]
    if not ids:
        return 0, None
    cur = conn.cursor()
    previas = []
    for tr in _trozos(ids, 400):
        cur.execute("SELECT id FROM sign_samples WHERE sign_id = ANY(%s::uuid[]) AND estado = 'aprobada'", (tr,))
        previas.extend(str(r[0]) for r in cur.fetchall())
    if seco or not previas:
        return len(previas), None
    estampa = estampa or datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    os.makedirs(carpeta, exist_ok=True)
    ruta = os.path.join(carpeta, f"devolver_revisar_{estampa}.sql")
    with open(ruta, "w", encoding="utf-8") as f:
        f.write(f"-- Devuelve a 'aprobada' las muestras de palabras [revisar] que se dejaron en espera ({estampa}).\n"
                "-- Antes, ponlas en [permitir] en tools/palabras_prohibidas.txt: si no, la siguiente\n"
                "-- corrida con --retener-revisar las vuelve a poner en espera.\n\n"
                "UPDATE sign_samples SET estado = 'aprobada'\nWHERE id IN (\n  "
                + ",\n  ".join(f"'{i}'" for i in sorted(previas)) + "\n);\n")
    try:
        for tr in _trozos(sorted(previas), 400):
            cur.execute("UPDATE sign_samples SET estado = 'pendiente' "
                        "WHERE id = ANY(%s::uuid[]) AND estado = 'aprobada'", (tr,))
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    return len(previas), ruta


def escribir_reporte(bloqueadas, por_revisar, carpeta, estampa, seco):
    os.makedirs(carpeta, exist_ok=True)
    ruta = os.path.join(carpeta, f"moderacion_{estampa}.csv")
    with open(ruta, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["nivel", "gloss", "espanol", "regla", "pendientes", "aprobadas", "rechazadas", "que_paso"])
        for b in bloqueadas:
            if b["pendientes"] or b["aprobadas"]:
                q = "se rechazaria (--seco)" if seco else "rechazada ahora"
            else:
                q = "ya estaba rechazada"
            w.writerow(["bloquear", b["gloss"], b["espanol"], b["regla"],
                        b["pendientes"], b["aprobadas"], b["rechazadas"], q])
        for b in por_revisar:
            w.writerow(["revisar", b["gloss"], b["espanol"], b["regla"],
                        b["pendientes"], b["aprobadas"], b["rechazadas"],
                        "no se aprueba sola; decide en palabras_prohibidas.txt"])
    return ruta


def glosas_marcadas_en_json(reglas, ruta):
    """Lee un plantillas.json y devuelve [(gloss, espanol, nivel, regla, plantillas)]."""
    with open(ruta, encoding="utf-8") as f:
        paquete = json.load(f)
    vistas = {}
    for p in paquete.get("plantillas", []):
        k = (p.get("gloss", ""), p.get("espanol", ""))
        vistas[k] = vistas.get(k, 0) + 1
    marcadas = []
    for (g, e), n in sorted(vistas.items()):
        v = evaluar(reglas, g, e)
        if v:
            marcadas.append((g, e, v[0], v[1], n))
    return marcadas, len(vistas), paquete.get("n_plantillas", sum(vistas.values()))


# ---------------------------------------------------------------------------
# Exportar plantillas.json (con respaldo), igual que el importador
# ---------------------------------------------------------------------------
def exportar_plantillas(destinos=None, respaldo=RESPALDO_DEFECTO, curar=True):
    """Regenera plantillas.json desde la base. Se exporta una vez y se copia al otro
    destino. Antes de pisar cada archivo guarda una copia en la carpeta de respaldo."""
    destinos = destinos or DESTINOS_DEFECTO
    estampa = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    validos = []
    for d in destinos:
        if os.path.isdir(os.path.dirname(d)):
            validos.append(d)
        else:
            log(f"  (no existe {os.path.dirname(d)}; salto ese destino)")
    if not validos:
        raise SystemExit("ninguno de los destinos de plantillas.json existe")
    for i, d in enumerate(validos):
        if os.path.exists(d):
            os.makedirs(respaldo, exist_ok=True)
            copia = os.path.join(respaldo, f"{i}_{estampa}_plantillas.json")
            shutil.copy2(d, copia)
            log(f"  respaldo: {copia}")
    r = subprocess.run([sys.executable, os.path.join(HERE, "exportar_paquete.py"), "--salida", validos[0]])
    if r.returncode != 0:
        raise SystemExit(f"exportar_paquete.py fallo para {validos[0]}")
    ruta_curar = os.path.join(HERE, "curar_plantillas.py")
    if curar and os.path.exists(ruta_curar):
        # rellena huecos cortos de mano, quita plantillas sin mano y deja de primera la mejor de cada
        # sena (G/H acostadas, J amplia, M limpia). No toca alturas ni posiciones. El respaldo ya se hizo.
        log("  curando plantillas (curar_plantillas.py)...")
        r2 = subprocess.run([sys.executable, ruta_curar, validos[0], "--sin-respaldo"])
        if r2.returncode != 0:
            log("  ! curar_plantillas.py fallo; se deja el paquete sin curar")
    for d in validos[1:]:
        shutil.copy2(validos[0], d)
    return validos


# ---------------------------------------------------------------------------
# Principal
# ---------------------------------------------------------------------------
def _mostrar_lista(titulo, filas, con_cuentas=True):
    log(titulo)
    for b in filas:
        extra = (f"  pendientes {b['pendientes']}, aprobadas {b['aprobadas']}"
                 if con_cuentas else "")
        log(f"  {b['gloss']:34s} (por: {b['regla']}){extra}")


def main():
    _consola_tolerante()
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lista", default=LISTA_DEFECTO, help="el .txt de palabras (tools/palabras_prohibidas.txt)")
    ap.add_argument("--seco", action="store_true", help="no cambia nada; solo dice que haria")
    ap.add_argument("--sin-curar", action="store_true",
                    help="al exportar, no correr curar_plantillas.py (huecos de mano, orden de la primera, sin-mano)")
    ap.add_argument("--probar", nargs="+", metavar="PALABRA",
                    help="dice como clasifica esas palabras (sin tocar la base)")
    ap.add_argument("--json", nargs="+", metavar="RUTA",
                    help="revisa uno o mas plantillas.json ya generados (sin tocar la base)")
    ap.add_argument("--retener-revisar", action="store_true",
                    help="las muestras ya APROBADAS de palabras [revisar] vuelven a 'pendiente' hasta que decidas")
    ap.add_argument("--exportar", action="store_true",
                    help="si se rechazo algo que estaba aprobado, regenera plantillas.json en los dos destinos")
    ap.add_argument("--destinos", nargs="+", default=DESTINOS_DEFECTO)
    ap.add_argument("--respaldo", default=RESPALDO_DEFECTO)
    ap.add_argument("--datos", default=DATOS_DEFECTO, help="donde dejar el reporte (datasets_lsm)")
    args = ap.parse_args()

    reglas = cargar_reglas(args.lista)
    log(f"lista: {reglas.ruta}\n  {len(reglas.bloquear)} reglas en [bloquear], "
        f"{len(reglas.revisar)} en [revisar], {len(reglas.permitir)} en [permitir]")

    if args.probar:
        log("")
        for palabra in args.probar:
            v = evaluar(reglas, a_glosa(palabra), palabra)
            if not v:
                log(f"  {palabra!r:34s} -> bien")
            else:
                accion = "BLOQUEADA" if v[0] == "bloquear" else "a revisar"
                log(f"  {palabra!r:34s} -> {accion}  (por: {v[1]})")
        return 0

    if args.json:
        malas = 0
        for ruta in args.json:
            try:
                marcadas, n_glosas, n_plantillas = glosas_marcadas_en_json(reglas, ruta)
            except (OSError, ValueError) as e:
                log(f"\n{ruta}: no pude leerlo ({e})")
                continue
            log(f"\n{ruta}: {n_glosas} senas, {n_plantillas} plantillas")
            bloq = [m for m in marcadas if m[2] == "bloquear"]
            rev = [m for m in marcadas if m[2] == "revisar"]
            if not marcadas:
                log("  ninguna coincide con la lista")
            for g, e, nivel, regla, n in bloq:
                log(f"  BLOQUEADA  {g}  ({n} plantillas, por: {regla})")
            for g, e, nivel, regla, n in rev:
                log(f"  a revisar  {g}  ({n} plantillas, por: {regla})")
            malas += len(bloq)
        if malas:
            log("\nHay palabras bloqueadas dentro del plantillas.json. Corre  "
                "python tools/moderar_senas.py --exportar  para sacarlas.")
        return 1 if malas else 0

    estampa = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    conn = conectar()
    try:
        bloqueadas, por_revisar, total = clasificar_base(conn, reglas)
        log(f"\n{total} senas en la base: {len(bloqueadas)} bloqueadas por la lista, "
            f"{len(por_revisar)} a revisar")
        if bloqueadas:
            log("")
            _mostrar_lista("BLOQUEADAS (quedan 'rechazada'):", bloqueadas)
        if por_revisar:
            log("")
            _mostrar_lista("A REVISAR (no se aprueban solas; decide en palabras_prohibidas.txt):", por_revisar)
        cambiadas, eran_aprobadas, ruta_sql = rechazar(
            conn, bloqueadas, seco=args.seco, carpeta=args.datos, estampa=estampa)
        revisar_aprobadas = sum(b["aprobadas"] for b in por_revisar)
        retenidas, ruta_ret = 0, None
        if args.retener_revisar:
            retenidas, ruta_ret = retener(conn, por_revisar, seco=args.seco, carpeta=args.datos, estampa=estampa)
    finally:
        conn.close()

    ruta_csv = escribir_reporte(bloqueadas, por_revisar, args.datos, estampa, args.seco)
    log("")
    if args.seco:
        log(f"(--seco: no se cambio nada)  se rechazarian {cambiadas} muestras "
            f"({eran_aprobadas} de ellas hoy aprobadas)")
    elif cambiadas:
        log(f"Listo: {cambiadas} muestras pasaron a 'rechazada' ({eran_aprobadas} eran aprobadas)")
        log(f"  para revertir: {ruta_sql}")
    else:
        log("No hubo nada que rechazar (las bloqueadas ya estaban rechazadas o no hay).")
    log(f"  reporte: {ruta_csv}")

    if args.retener_revisar:
        log(f"\nA REVISAR que estaban aprobadas: {retenidas} muestras "
            + ("pasarian a 'pendiente' (--seco)" if args.seco else "pasaron a 'pendiente' (en espera)"))
        if ruta_ret:
            log(f"  para devolverlas: {ruta_ret}")
    elif revisar_aprobadas:
        log(f"\nOJO: {revisar_aprobadas} muestras de palabras A REVISAR estan APROBADAS y entrarian a plantillas.json.\n"
            "  Para dejarlas en espera:  python tools/moderar_senas.py --retener-revisar")
    if args.exportar and not args.seco:
        log("\nplantillas.json")
        for d in exportar_plantillas(args.destinos, args.respaldo, curar=not args.sin_curar):
            try:
                with open(d, encoding="utf-8") as f:
                    p = json.load(f)
                log(f"  {d}: {p['n_senas']} senas, {p['n_plantillas']} plantillas")
            except Exception as e:  # noqa: BLE001
                log(f"  {d}: no pude releerlo ({e})")
        log("Ahora un  flutter run  completo (no hot reload) para que la app tome el archivo.")
    elif (eran_aprobadas or retenidas) and not args.seco:
        log(f"\nOJO: {eran_aprobadas + retenidas} muestras estaban aprobadas en la base. Si tu plantillas.json se "
            "genero cuando lo estaban, regeneralo para sacarlas de la app:\n"
            "    python tools/moderar_senas.py --exportar")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("\ninterrumpido")
        sys.exit(130)
