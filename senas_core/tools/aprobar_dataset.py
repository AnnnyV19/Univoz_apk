#!/usr/bin/env python3
"""Aprueba por TANDAS las muestras 'pendiente' de un dataset (Wikisigns, ITESO...)
para que entren a plantillas.json, y regenera ese archivo. Nada se aprueba solo
ni de golpe.

Antes de aprobar nada, pasa la lista de tools/palabras_prohibidas.txt:
  - lo de [bloquear] queda 'rechazada' (ver moderar_senas.py) y nunca se aprueba
  - lo de [revisar] se salta hasta que lo muevas a [permitir] o a [bloquear]

Despues escoge, de lo que queda, las MEJORES tomas primero (las que tienen mas
cuadros con mano detectada), una por palabra antes de repetir palabra, hasta
completar --limite. Es acumulativo: --limite 300 y luego --limite 600 deja 600 en
total, no 900. Por defecto:
  - no toca palabras que YA tenias aprobadas por otro lado (--existentes sumar para
    agregar tambien esas)
  - descarta tomas con menos de 60% de cuadros con mano (--minimo-manos)
  - varios sinonimos pueden compartir un mismo video; por defecto entran todos
    (el avatar los necesita). --compartidos una deja solo uno por video: plantillas.json
    pesa menos y el reconocedor no se confunde entre sinonimos identicos

Para llegar a N grabaciones por sena (en vez de un total):  --por-glosa N  aprueba, de cada sena de este
dataset, las mejores tomas que hagan falta para que la sena llegue a N en total (cuenta lo que ya tiene
aprobado de cualquier origen, sin los espejos). Implica --existentes sumar. Ver tools/cobertura_muestras.py.

USO (desde senas_core)
    python tools/aprobar_dataset.py --seco                       # tabla de tandas, no cambia nada
    python tools/aprobar_dataset.py --dataset iteso --por-glosa 10 --seco   # que haria para llegar a 10 por sena
    python tools/aprobar_dataset.py --limite 300 --seco          # que aprobaria
    python tools/aprobar_dataset.py --limite 300                 # aprueba y regenera plantillas.json
    python tools/aprobar_dataset.py --limite 300 --sin-exportar  # solo aprueba
    python tools/aprobar_dataset.py --revertir                   # todo el dataset vuelve a 'pendiente'

Despues de exportar, hace falta un  flutter run  completo (los assets se empaquetan al
compilar; con hot reload no se ven).

Deja en datasets_lsm/:
    aprobacion_<fecha>.csv          cada toma: aprobada / omitida y por que
    volver_a_pendiente_<fecha>.sql  para deshacer esta tanda
"""

import argparse
import csv
import datetime
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import sign_norm as sn  # noqa: E402
import moderar_senas as mod  # noqa: E402
from moderar_senas import log  # noqa: E402

# Como empieza el video_uri de lo que importo cada dataset (ver importar_dataset_lsm.py)
PREFIJOS = {
    "wikisigns": "wikisigns:lsm/",
    "iteso": "mendeley:g45jkzys4f/",
    "uaemex": "mendeley:6rj76z6y3n/",
    "medico": "zenodo:18330565/",
    "alfabeto": "zenodo:14689869/",
    "alfabeto_estatico": "zenodo:10067509/",
}
RX_YT = re.compile(r"__([A-Za-z0-9_-]{11})\.[A-Za-z0-9]+#t\d+$")

# Estimaciones para avisar del tamano (no son una medicion de tu telefono):
JSON_POR_PLANTILLA = 41_000            # bytes de plantillas.json por plantilla (tu archivo actual)
RAM_POR_PLANTILLA_MB = 0.2             # List<List<double>> en Dart, x2 por el espejo automatico


def _num(x, defecto=0.0):
    try:
        return float(x)
    except (TypeError, ValueError):
        return defecto


def fraccion_con_mano(seq):
    n = len(seq)
    if not n:
        return 0.0
    return sum(1 for fr in seq
               if fr[sn.OFF_PRES_L] > 0.5 or fr[sn.OFF_PRES_R] > 0.5) / n


REPOSO_Y = -0.9      # muneca mas abajo de esto (anchos de hombro, arriba +) = brazo colgando


def altura_stats(seq):
    """Altura de muneca de una toma, SIN cambiar nada: modo ('mano' si el cuerpo es el esqueleto neutro de
    los videos sin hombros: sus codos no se mueven y la altura de muneca es sintetica, o 'cuerpo'),
    pico (percentil 90 de la altura de la muneca con mano presente) y reposo (fraccion de esos cuadros con
    el brazo colgando, muneca < REPOSO_Y). Es la misma medida de tools/comparar_uaemex_alturas.py."""
    if not seq:
        return {"modo": None, "pico": None, "reposo": None}
    rango_codos = max(max(fr[d] for fr in seq) - min(fr[d] for fr in seq) for d in range(6, 12))
    modo = "mano" if rango_codos < 0.01 else "cuerpo"
    ys = []
    for fr in seq:
        for off_pres, off_loc in ((sn.OFF_PRES_L, sn.OFF_LOC_L), (sn.OFF_PRES_R, sn.OFF_LOC_R)):
            if fr[off_pres] > 0.5:
                ys.append(fr[off_loc + 1])
    if not ys:
        return {"modo": modo, "pico": None, "reposo": None}
    ys.sort()
    return {"modo": modo, "pico": ys[min(len(ys) - 1, int(0.9 * len(ys)))],
            "reposo": sum(1 for y in ys if y < REPOSO_Y) / len(ys)}


def bytes_json(seq):
    """Lo que ocupa esta plantilla en plantillas.json (mismo formato que exportar_paquete.py)."""
    return len(json.dumps(
        {"sign_id": "00000000-0000-0000-0000-000000000000", "gloss": "XXXXXXXXXXXX",
         "espanol": "xxxxxxxxxxxx",
         "seq": [[round(float(x), 6) for x in fr] for fr in seq]}))


def cargar_metadatos(conn, prefijo):
    """Todas las muestras de ese dataset (sin los landmarks)."""
    cur = conn.cursor()
    cur.execute(
        """SELECT ss.id, ss.sign_id, s.gloss, s.espanol, ss.estado, ss.quality_score,
                  ss.visibilidad_min, ss.video_uri
           FROM sign_samples ss JOIN signs s ON s.id = ss.sign_id
           WHERE ss.video_uri LIKE %s AND ss.origen = 'video'
           ORDER BY s.gloss, ss.video_uri""", (prefijo + "%",))
    filas = []
    for mid, sid, gloss, espanol, estado, q, vis, uri in cur.fetchall():
        m = RX_YT.search(uri or "")
        filas.append({"id": str(mid), "sign_id": str(sid), "gloss": gloss, "espanol": espanol or "",
                      "estado": estado, "calidad": _num(q), "vis": _num(vis), "uri": uri or "",
                      "yt": m.group(1) if m else None})
    return filas


def signs_con_muestras_de_otro_origen(conn, prefijo):
    """Senas que ya tienen alguna muestra aprobada que NO es de este dataset (las tuyas)."""
    cur = conn.cursor()
    cur.execute(
        """SELECT DISTINCT sign_id FROM sign_samples
           WHERE estado = 'aprobada' AND (video_uri IS NULL OR video_uri NOT LIKE %s)""",
        (prefijo + "%",))
    return {str(r[0]) for r in cur.fetchall()}


def aprobadas_por_sena(conn):
    """{sign_id: n} de grabaciones aprobadas (de cualquier origen) que NO son espejos: el espejo de una
    toma es la misma grabacion."""
    cur = conn.cursor()
    cur.execute("SELECT ss.sign_id, count(*) FROM sign_samples ss JOIN sample_landmarks sl ON sl.sample_id = ss.id "
                "WHERE ss.estado = 'aprobada' AND ss.origen <> 'espejo' AND sl.norm_version = %s "
                "GROUP BY ss.sign_id", (sn.NORM_VERSION,))
    return {str(r[0]): int(r[1]) for r in cur.fetchall()}


def elegir_por_glosa(cand, tengo, objetivo):
    """De cada sena, las mejores tomas (mas cuadros con mano, mejor calidad) hasta que llegue a `objetivo`.
    Devuelve (nuevas, resumen) con resumen = {gloss: (tenia, aprueba)}."""
    por = {}
    for f in cand:
        por.setdefault(f["gloss"], []).append(f)
    nuevas, resumen = [], {}
    for g, lista in por.items():
        lista.sort(key=lambda x: (-x["manos"], -x["calidad"], -x["vis"], x["uri"]))
        tenia = tengo.get(lista[0]["sign_id"], 0)
        k = max(0, objetivo - tenia)
        nuevas.extend(lista[:k])
        resumen[g] = (tenia, min(k, len(lista)))
    return nuevas, resumen


def total_aprobadas(conn):
    cur = conn.cursor()
    cur.execute("SELECT count(*) FROM sign_samples ss JOIN sample_landmarks sl ON sl.sample_id = ss.id "
                "WHERE ss.estado = 'aprobada' AND sl.norm_version = %s", (sn.NORM_VERSION,))
    return int(cur.fetchone()[0])


def leer_manos(conn, filas):
    """Agrega 'manos' (fraccion de cuadros con mano) a cada fila, y devuelve el promedio de bytes JSON."""
    cur = conn.cursor()
    por_id = {f["id"]: f for f in filas}
    ids = list(por_id)
    tam = []
    for i in range(0, len(ids), 150):
        trozo = ids[i:i + 150]
        cur.execute("SELECT sample_id, data, frame_dim FROM sample_landmarks "
                    "WHERE sample_id = ANY(%s::uuid[]) AND norm_version = %s", (trozo, sn.NORM_VERSION))
        for sid, blob, dim in cur.fetchall():
            seq = sn.unpack_f16(bytes(blob), dim=int(dim))
            f = por_id[str(sid)]
            f["manos"] = fraccion_con_mano(seq)
            f.update(altura_stats(seq))
            if len(tam) < 20:
                tam.append(bytes_json(seq))
    for f in filas:
        f.setdefault("manos", None)
        f.setdefault("modo", None)
        f.setdefault("pico", None)
        f.setdefault("reposo", None)
    return (sum(tam) / len(tam)) if tam else JSON_POR_PLANTILLA


def planear(filas, reglas, ocupadas, args):
    """Decide que se aprueba. Devuelve (lista ordenada de candidatas, resumen de omisiones).
    Cada fila recibe 'decision' y 'motivo'."""
    omit = {"bloqueada": 0, "a revisar": 0, "ya tenia la sena": 0, "poca mano": 0, "sinonimo": 0}
    ya_aprobadas = 0
    cand = []
    for f in filas:
        f["decision"], f["motivo"] = "", ""
        if f["estado"] == "aprobada":
            f["decision"], f["motivo"] = "ya aprobada", ""
            ya_aprobadas += 1
            continue
        if f["estado"] == "rechazada":
            v = mod.evaluar(reglas, f["gloss"], f["espanol"])
            f["decision"] = "omitida"
            f["motivo"] = "rechazada" + (" (bloqueada por la lista)" if v and v[0] == "bloquear" else "")
            continue
        v = mod.evaluar(reglas, f["gloss"], f["espanol"])
        if v and v[0] == "bloquear":
            f["decision"], f["motivo"] = "omitida", f"bloqueada ({v[1]})"
            omit["bloqueada"] += 1
        elif v and v[0] == "revisar":
            f["decision"], f["motivo"] = "omitida", f"a revisar ({v[1]})"
            omit["a revisar"] += 1
        elif args.existentes == "omitir" and f["sign_id"] in ocupadas:
            f["decision"], f["motivo"] = "omitida", "ya tenias esa sena"
            omit["ya tenia la sena"] += 1
        else:
            cand.append(f)

    # Sinonimos que comparten video: con --compartidos una se queda solo uno por video
    if args.compartidos == "una":
        grupos = {}
        for f in cand:
            if f["yt"]:
                grupos.setdefault(f["yt"], []).append(f)
        for yt, g in grupos.items():
            if len({x["sign_id"] for x in g}) > 1:
                g.sort(key=lambda x: (len(x["gloss"]), x["gloss"]))
                for x in g[1:]:
                    if x["sign_id"] != g[0]["sign_id"]:
                        x["decision"], x["motivo"] = "omitida", f"sinonimo del video de {g[0]['gloss']}"
                        omit["sinonimo"] += 1
        cand = [f for f in cand if not f["decision"]]
    return cand, omit, ya_aprobadas


def filtrar_alturas(cand, args, omit):
    """Marca como 'omitida' las candidatas que no pasan los filtros de altura pedidos (--sin-solo-mano,
    --pico-minimo, --reposo-maximo). No cambia ninguna altura: solo decide cuales entran."""
    for f in cand:
        if f["decision"]:
            continue
        if args.sin_solo_mano and f.get("modo") == "mano":
            f["decision"], f["motivo"] = "omitida", "solo mano (altura sintetica)"
            omit["solo mano"] = omit.get("solo mano", 0) + 1
        elif args.pico_minimo is not None and f.get("pico") is not None and f["pico"] < args.pico_minimo:
            f["decision"], f["motivo"] = "omitida", \
                f"la mano no sube de {f['pico']:+.2f} (minimo {args.pico_minimo:+.2f})"
            omit["mano baja"] = omit.get("mano baja", 0) + 1
        elif args.reposo_maximo is not None and f.get("reposo") is not None and f["reposo"] > args.reposo_maximo:
            f["decision"], f["motivo"] = "omitida", \
                f"brazo colgando en {f['reposo']:.0%} de los cuadros (maximo {args.reposo_maximo:.0%})"
            omit["mucho reposo"] = omit.get("mucho reposo", 0) + 1


def ordenar(cand, ya_por_gloss):
    """Mejor primero; una toma por palabra antes de repetir palabra (contando las que ya
    se aprobaron en tandas anteriores: la segunda toma de una palabra espera su turno)."""
    por_gloss = {}
    for f in cand:
        por_gloss.setdefault(f["gloss"], []).append(f)
    orden = []
    for g, lista in por_gloss.items():
        lista.sort(key=lambda x: (-x["manos"], -x["calidad"], -x["vis"], x["uri"]))
        for i, f in enumerate(lista):
            f["vuelta"] = ya_por_gloss.get(g, 0) + i
            orden.append(f)
    orden.sort(key=lambda x: (x["vuelta"], -x["manos"], -x["calidad"], -x["vis"], x["gloss"], x["uri"]))
    return orden


def info_archivo(destinos):
    """(bytes, n_plantillas) del plantillas.json que usa la app hoy; None donde no se sepa."""
    for d in destinos:
        if os.path.exists(d):
            tam = os.path.getsize(d)
            try:
                with open(d, encoding="utf-8") as f:
                    cab = f.read(500)
                # curar_plantillas.py quita plantillas sin mano: n_exportadas es lo que salio de la base
                m = re.search(r'"n_exportadas":\s*(\d+)', cab) or re.search(r'"n_plantillas":\s*(\d+)', cab)
                n = int(m.group(1)) if m else None
            except (OSError, ValueError):
                n = None
            return tam, n
    return None, None


def tabla_de_tandas(n_hoy, bytes_hoy, prom_nuevas, disponibles):
    log("\nTandas posibles (estimado: plantillas.json y memoria del telefono al cargarlo):")
    log(f"  {'tanda':>8}  {'plantillas':>10}  {'plantillas.json':>15}  {'memoria aprox.':>14}")
    filas = [("hoy", 0)]
    for n in (150, 300, 600, 1000):
        if n < disponibles:
            filas.append((str(n), n))
    filas.append((f"todas ({disponibles:,})", disponibles))
    for etiqueta, n in filas:
        total = n_hoy + n
        mb = (bytes_hoy + n * prom_nuevas) / 1e6
        log(f"  {etiqueta:>8}  {total:>10,}  {('~%.0f MB' % mb):>15}  {('~%.0f MB' % (total * RAM_POR_PLANTILLA_MB)):>14}")
    log("  (la memoria sale de leer plantillas.dart: cada plantilla se guarda como lista de listas de\n"
        "   doubles y el espejo automatico la duplica; es una estimacion, no una medicion de tu celular)")


def escribir_csv(filas, carpeta, estampa, seco):
    os.makedirs(carpeta, exist_ok=True)
    ruta = os.path.join(carpeta, f"aprobacion_{estampa}{'_seco' if seco else ''}.csv")
    with open(ruta, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["decision", "motivo", "gloss", "espanol", "cuadros_con_mano", "calidad", "video_uri",
                    "modo", "altura_pico", "reposo"])
        orden = {"aprobar": 0, "candidata": 0, "ya aprobada": 1, "omitida": 2}
        for r in sorted(filas, key=lambda x: (orden.get(x["decision"], 3), x["gloss"], x["uri"])):
            w.writerow([r["decision"], r["motivo"], r["gloss"], r["espanol"],
                        "" if r.get("manos") is None else f"{r['manos']:.2f}",
                        f"{r['calidad']:.2f}", r["uri"], r.get("modo") or "",
                        "" if r.get("pico") is None else f"{r['pico']:.2f}",
                        "" if r.get("reposo") is None else f"{r['reposo']:.2f}"])
    return ruta


def main():
    mod._consola_tolerante()
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dataset", choices=sorted(PREFIJOS), default="wikisigns")
    ap.add_argument("--limite", type=int, metavar="N",
                    help="cuantas muestras de este dataset deben quedar aprobadas EN TOTAL (acumulativo)")
    ap.add_argument("--todas", action="store_true", help="sin limite (no recomendado de golpe; mira la tabla con --seco)")
    ap.add_argument("--por-glosa", type=int, metavar="N",
                    help="de cada sena de este dataset, aprobar las mejores tomas que hagan falta para que llegue a N "
                         "grabaciones aprobadas EN TOTAL (cuenta las de cualquier origen, sin espejos). Implica "
                         "--existentes sumar. Ejemplo: --dataset iteso --por-glosa 10")
    ap.add_argument("--minimo-manos", type=float, default=0.6, metavar="F",
                    help="fraccion minima de cuadros con mano detectada (0.6)")
    ap.add_argument("--sin-solo-mano", action="store_true",
                    help="omite las tomas en modo 'solo mano' (esqueleto neutro: su altura de muneca es SINTETICA, "
                         "no la de la persona)")
    ap.add_argument("--pico-minimo", type=float, default=None, metavar="H",
                    help="omite las tomas cuya muneca (percentil 90) nunca sube de H anchos de hombro, p. ej. -0.5 "
                         "(brazos colgando o la mano no se detecto cuando subio). No cambia ninguna altura")
    ap.add_argument("--reposo-maximo", type=float, default=None, metavar="F",
                    help="omite las tomas con mas de esta fraccion de cuadros con la muneca colgando (< -0.9), p. ej. 0.5")
    ap.add_argument("--existentes", choices=["omitir", "sumar"], default="omitir",
                    help="senas que ya tenias aprobadas por otro lado: omitir (defecto) las deja como estan; "
                         "sumar agrega tambien las del dataset (cambia lo que ya probaste)")
    ap.add_argument("--compartidos", choices=["todas", "una"], default="todas",
                    help="sinonimos que comparten un mismo video: todas (defecto) o una por video")
    ap.add_argument("--lista", default=mod.LISTA_DEFECTO)
    ap.add_argument("--seco", action="store_true", help="no cambia nada; muestra el plan")
    ap.add_argument("--sin-exportar", action="store_true", help="aprueba pero no toca plantillas.json")
    ap.add_argument("--sin-curar", action="store_true",
                    help="al exportar, no correr curar_plantillas.py (huecos de mano, orden de la primera, sin-mano)")
    ap.add_argument("--revertir", action="store_true",
                    help="todas las muestras aprobadas de este dataset vuelven a 'pendiente'")
    ap.add_argument("--destinos", nargs="+", default=mod.DESTINOS_DEFECTO)
    ap.add_argument("--respaldo", default=mod.RESPALDO_DEFECTO)
    ap.add_argument("--datos", default=mod.DATOS_DEFECTO, help="donde dejar los reportes (datasets_lsm)")
    args = ap.parse_args()

    if args.limite is not None and args.limite < 0:
        raise SystemExit("--limite no puede ser negativo")
    if args.limite is not None and args.todas:
        raise SystemExit("usa --limite N o --todas, no los dos")
    if args.por_glosa is not None:
        if args.por_glosa < 1:
            raise SystemExit("--por-glosa tiene que ser 1 o mas")
        if args.limite is not None or args.todas:
            raise SystemExit("--por-glosa no se combina con --limite ni --todas")
        args.existentes = "sumar"       # el objetivo es justo sumar a lo que ya tiene cada sena
    if not (args.seco or args.revertir or args.todas or args.limite is not None or args.por_glosa is not None):
        raise SystemExit("falta decir cuantas: --limite N (por ejemplo 300) o --por-glosa N (por ejemplo 10). "
                         "Para ver las opciones sin cambiar nada:  python tools/aprobar_dataset.py --seco")

    prefijo = PREFIJOS[args.dataset]
    reglas = mod.cargar_reglas(args.lista)
    estampa = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    log(f"dataset: {args.dataset}   lista de palabras: {len(reglas.bloquear)} a bloquear, "
        f"{len(reglas.revisar)} a revisar, {len(reglas.permitir)} permitidas"
        + ("   (--seco: no se cambia nada)" if args.seco else ""))

    conn = mod.conectar()
    try:
        # --- 1. moderacion de TODA la base ------------------------------------------------------
        bloqueadas, por_revisar, _total = mod.clasificar_base(conn, reglas)
        cambiadas, eran_aprobadas, ruta_rev = mod.rechazar(
            conn, bloqueadas, seco=args.seco, carpeta=args.datos, estampa=estampa)
        log(f"\n[1] Palabras prohibidas: {len(bloqueadas)} senas bloqueadas"
            + (f", {cambiadas} muestras" + (" se rechazarian" if args.seco else " pasaron a 'rechazada'")
               + (f" ({eran_aprobadas} estaban aprobadas)" if eran_aprobadas else "") if cambiadas else
               " (ya estaban rechazadas)")
            + f"; {len(por_revisar)} a revisar (no se aprueban)")
        revisar_aprobadas = sum(b["aprobadas"] for b in por_revisar)
        if revisar_aprobadas:
            log(f"    OJO: {revisar_aprobadas} muestras de palabras A REVISAR ya estan APROBADAS (entrarian al export): "
                "python tools/moderar_senas.py --retener-revisar")
        if ruta_rev:
            log(f"    para revertir: {ruta_rev}")
        hay_cambio_aprobadas = bool(eran_aprobadas) and not args.seco

        filas = cargar_metadatos(conn, prefijo)
        if not filas:
            raise SystemExit(f"no hay muestras de {args.dataset} en la base (video_uri que empiece con {prefijo})")

        # --- revertir ----------------------------------------------------------------------------
        if args.revertir:
            ids = [f["id"] for f in filas if f["estado"] == "aprobada"]
            log(f"\n[2] Revertir: {len(ids)} muestras de {args.dataset} vuelven a 'pendiente'"
                + ("  (--seco)" if args.seco else ""))
            if ids and not args.seco:
                cur = conn.cursor()
                try:
                    for i in range(0, len(ids), 400):
                        cur.execute("UPDATE sign_samples SET estado = 'pendiente' "
                                    "WHERE id = ANY(%s::uuid[]) AND estado = 'aprobada'", (ids[i:i + 400],))
                    conn.commit()
                except Exception:
                    conn.rollback()
                    raise
            if args.seco:
                log("\n(--seco: no se cambio nada)")
                return 0
            if args.sin_exportar:
                log("\n(--sin-exportar: plantillas.json no se toco)")
                return 0
            nuevas_aprobadas, ruta_sql = ids, None
        else:
            # --- 2. que se puede aprobar ---------------------------------------------------------
            ocupadas = signs_con_muestras_de_otro_origen(conn, prefijo)
            cand, omit, ya = planear(filas, reglas, ocupadas, args)
            # los landmarks solo de las candidatas (ya filtradas por lista / existentes / sinonimos)
            prom = leer_manos(conn, cand)
            pocas = [f for f in cand if f["manos"] is None or f["manos"] < args.minimo_manos]
            for f in pocas:
                f["decision"] = "omitida"
                f["motivo"] = ("sin landmarks de esta version" if f["manos"] is None
                               else f"pocos cuadros con mano ({f['manos']:.0%})")
            omit["poca mano"] = len(pocas)
            filtrar_alturas(cand, args, omit)
            cand = [f for f in cand if not f["decision"]]
            ya_por_gloss = {}
            for f in filas:
                if f["estado"] == "aprobada":
                    ya_por_gloss[f["gloss"]] = ya_por_gloss.get(f["gloss"], 0) + 1
            orden = ordenar(cand, ya_por_gloss)

            pend = sum(1 for f in filas if f["estado"] == "pendiente")
            log(f"\n[2] {args.dataset}: {len(filas):,} muestras en la base: {ya} aprobadas, {pend:,} pendientes")
            if any(omit.values()):
                log("    omitidas: " + ", ".join(f"{v:,} {k}" for k, v in omit.items() if v))
            else:
                log("    omitidas: ninguna")
            log(f"    se pueden aprobar: {len(orden):,} muestras de {len({f['gloss'] for f in orden}):,} palabras "
                f"(con >= {args.minimo_manos:.0%} de cuadros con mano)")

            n_hoy = total_aprobadas(conn)
            tam_arch, n_arch = info_archivo(args.destinos)
            archivo_mb = tam_arch / 1e6 if tam_arch else None
            bpp = tam_arch / n_arch if (tam_arch and n_arch) else JSON_POR_PLANTILLA
            bytes_hoy = n_hoy * bpp          # lo que pesaria plantillas.json con lo aprobado hoy en la base
            if (args.seco or args.limite is None) and args.por_glosa is None:
                tabla_de_tandas(n_hoy, bytes_hoy, prom, len(orden))

            cupo = 0
            resumen_pg = None
            if args.por_glosa is not None:
                tengo = aprobadas_por_sena(conn)
                nuevas, resumen_pg = elegir_por_glosa(orden, tengo, args.por_glosa)
                cupo = len(nuevas)
            elif args.limite is None and not args.todas:      # --seco sin limite: solo la tabla
                nuevas = []
            else:
                cupo = len(orden) if args.todas else max(0, args.limite - ya)
                nuevas = orden[:cupo]
            for f in nuevas:
                f["decision"], f["motivo"] = "aprobar", ""
            for f in orden:
                if f["decision"] == "aprobar":
                    continue
                if args.por_glosa is not None:
                    f["decision"], f["motivo"] = "omitida", f"la sena ya llega a {args.por_glosa} (queda pendiente)"
                elif args.limite is None and not args.todas:
                    f["decision"], f["motivo"] = "candidata", "se puede aprobar (falta elegir --limite)"
                else:
                    f["decision"], f["motivo"] = "omitida", "fuera de esta tanda (queda pendiente)"
            if resumen_pg is not None:
                antes = sum(1 for (t, _a) in resumen_pg.values() if t >= args.por_glosa)
                llegan = sum(1 for (t, a) in resumen_pg.values() if t + a >= args.por_glosa)
                faltan = sorted(((g, t + a) for g, (t, a) in resumen_pg.items() if t + a < args.por_glosa),
                                key=lambda x: (-x[1], x[0]))
                log(f"\n[3] --por-glosa {args.por_glosa}: {len(nuevas):,} muestras nuevas para {len(resumen_pg):,} senas "
                    f"de {args.dataset}")
                log(f"    ya llegaban a {args.por_glosa}: {antes:,}   |   llegan tras aprobar: {llegan:,}   |   "
                    f"quedan por debajo: {len(faltan):,}")
                if faltan:
                    log("    por debajo (con cuantas quedarian): " +
                        ", ".join(f"{g} {n}" for g, n in faltan[:14]) + (" ..." if len(faltan) > 14 else ""))
                if nuevas:
                    mb = (bytes_hoy + len(nuevas) * prom) / 1e6
                    log(f"    plantillas.json quedaria en ~{mb:.0f} MB con {n_hoy + len(nuevas):,} plantillas "
                        f"(~{(n_hoy + len(nuevas)) * RAM_POR_PLANTILLA_MB:.0f} MB de memoria en el telefono, estimado; "
                        "cada toma nueva suma tambien su espejo)")
                    log(f"    la menos buena que entra tiene {min(f['manos'] for f in nuevas):.0%} de cuadros con mano")
            if (args.limite is not None or args.todas) and resumen_pg is None:
                glosas = sorted({f["gloss"] for f in nuevas})
                log(f"\n[3] Tanda: {len(nuevas):,} muestras nuevas de {len(glosas):,} palabras "
                    f"(en total quedan {ya + len(nuevas):,} de {args.dataset})")
                if nuevas:
                    log(f"    la menos buena que entra tiene {min(f['manos'] for f in nuevas):.0%} de cuadros con mano")
                    log("    ejemplos: " + ", ".join(glosas[:: max(1, len(glosas) // 14)][:14]))
                    mb = (bytes_hoy + len(nuevas) * prom) / 1e6
                    hoy = (f"; hoy el archivo de la app pesa {archivo_mb:.0f} MB" if archivo_mb else "")
                    log(f"    plantillas.json quedaria en ~{mb:.0f} MB con {n_hoy + len(nuevas):,} plantillas{hoy} "
                        f"(~{(n_hoy + len(nuevas)) * RAM_POR_PLANTILLA_MB:.0f} MB de memoria en el telefono, estimado)")
            nuevas_aprobadas = nuevas
            ruta_sql = None
            ruta_csv = escribir_csv(filas, args.datos, estampa, args.seco)
            log(f"    detalle de cada toma: {ruta_csv}")

            if not args.seco and nuevas:
                ruta_sql = os.path.join(args.datos, f"volver_a_pendiente_{estampa}.sql")
                ids = [f["id"] for f in nuevas]
                with open(ruta_sql, "w", encoding="utf-8") as fh:
                    fh.write("-- Deshace la tanda del %s: esas muestras vuelven a 'pendiente'.\n"
                             "-- Despues: python tools/moderar_senas.py --exportar  (o exportar_paquete.py)\n\n"
                             "UPDATE sign_samples SET estado = 'pendiente'\nWHERE id IN (\n  %s\n);\n"
                             % (estampa, ",\n  ".join("'%s'" % i for i in ids)))
                cur = conn.cursor()
                try:
                    for i in range(0, len(ids), 400):
                        cur.execute("UPDATE sign_samples SET estado = 'aprobada' "
                                    "WHERE id = ANY(%s::uuid[]) AND estado = 'pendiente'", (ids[i:i + 400],))
                    conn.commit()
                except Exception:
                    conn.rollback()
                    raise
                log(f"\n    APROBADAS {len(ids):,} muestras.  para deshacer: {ruta_sql}")
            elif not args.seco:
                if args.por_glosa is not None:
                    log("\n    ninguna sena de este dataset necesita mas tomas para llegar a "
                        f"{args.por_glosa}, o no hay tomas pendientes que cumplan los criterios")
                elif cupo <= 0:
                    log(f"\n    ya hay {ya:,} aprobadas de {args.dataset} (= el limite); sube --limite para aprobar mas")
                else:
                    log("\n    no quedan muestras que cumplan los criterios")
        n_final = None if args.seco else total_aprobadas(conn)
    finally:
        conn.close()

    if args.seco:
        log("\n(--seco: no se cambio nada)")
        return 0
    if args.sin_exportar:
        log("\n(--sin-exportar: plantillas.json no se toco; para regenerarlo: python tools/moderar_senas.py --exportar)")
        return 0
    _tam, n_archivo = info_archivo(args.destinos)
    if not (nuevas_aprobadas or hay_cambio_aprobadas) and n_archivo is not None and n_archivo == n_final:
        log(f"\nplantillas.json ya esta al dia ({n_final:,} plantillas); no hace falta exportar.")
        return 0

    log("\n[4] plantillas.json")
    hechos = mod.exportar_plantillas(args.destinos, args.respaldo, curar=not args.sin_curar)
    malos = 0
    for d in hechos:
        try:
            marcadas, n_gl, n_pl = mod.glosas_marcadas_en_json(reglas, d)
        except (OSError, ValueError) as e:
            log(f"  {d}: no pude releerlo ({e})")
            continue
        log(f"  {d}: {n_gl:,} senas, {n_pl:,} plantillas, {os.path.getsize(d) / 1e6:.1f} MB")
        for g, _e, nivel, regla, n in marcadas:
            if nivel == "bloquear":
                malos += 1
                log(f"  !! {g} esta bloqueada (por: {regla}) y aparece en el archivo")
    if malos:
        raise SystemExit("hay palabras bloqueadas en el plantillas.json; no lo uses y avisame")
    log("\nListo. Ahora un  flutter run  COMPLETO (no hot reload) para que la app tome el archivo.\n"
        "Pruebalo en el telefono (carga, que no se cierre, que reconozca) antes de subir el --limite.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("\ninterrumpido")
        sys.exit(130)
