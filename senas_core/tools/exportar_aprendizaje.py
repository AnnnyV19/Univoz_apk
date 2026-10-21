#!/usr/bin/env python3
"""Exporta las señas SOLO DE APRENDIZAJE (por defecto, el Glosario Digital de LSM de INDISCAPACIDAD CDMX,
video_uri 'indiscapacidad:...') a univoz/assets/aprendizaje.json, para que el avatar y el Diccionario de la app
las muestren.

Qué hace y qué NO hace:
  * Una plantilla por seña: la mejor toma (más cuadros con mano, luego calidad).
  * NO entran al reconocimiento: la app las carga aparte (plantillas.dart -> Diccionario.aprendizaje) y nunca
    las mete al clasificador.
  * NO cambia NADA en la base (no aprueba ni rechaza muestras) ni toca plantillas.json.
  * Respeta tools/palabras_prohibidas.txt: lo de [bloquear] y lo de [revisar] se omite.
  * Por defecto omite las señas que la app YA tiene en plantillas.json (el avatar sigue usando la curada).
  * Curado igual que tools/curar_plantillas.py: rellena huecos cortos de mano y corrige la forma de la mano
    por el aspecto de la imagen (forma "iso1"). NO toca alturas ni la posición de ningún cuadro con mano.
  * Para que el archivo pese poco, cada secuencia va en float16 (el mismo formato con que se guarda en la base)
    codificada en base64: ~13 KB por seña en vez de ~40 KB.

USO (desde senas_core):
    python tools/exportar_aprendizaje.py --seco      # cuántas saldrían y cuánto pesaría; no escribe nada
    python tools/exportar_aprendizaje.py             # escribe D:\\UNIVOZ_APK\\univoz\\assets\\aprendizaje.json
Después: flutter run completo (los assets se empaquetan al compilar).
"""

import argparse
import base64
import csv
import datetime
import json
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, HERE)

T, D = 32, 152
OFF_LOC = (24, 27)
OFF_PRES = (30, 31)

SALIDA_DEFECTO = r"D:\UNIVOZ_APK\univoz\assets\aprendizaje.json"
PLANTILLAS_APP = r"D:\UNIVOZ_APK\univoz\assets\plantillas.json"
DATOS_DEFECTO = os.path.join(RAIZ, "datasets_lsm")
FUENTES = {
    "indiscapacidad:": {
        "nombre": "Glosario Digital de Lengua de Señas Mexicana (INDISCAPACIDAD CDMX)",
        "url": "https://lsm.indiscapacidad.cdmx.gob.mx/",
        "entradas": os.path.join(DATOS_DEFECTO, "indiscapacidad_gdlsm", "entradas.csv"),
    },
}


def log(*a):
    print(*a, flush=True)


def fraccion_con_mano(seq):
    if not seq:
        return 0.0
    return sum(1 for fr in seq if fr[OFF_PRES[0]] > 0.5 or fr[OFF_PRES[1]] > 0.5) / len(seq)


def a_f16_b64(seq):
    flat = [float(x) for fr in seq for x in fr]
    return base64.b64encode(struct.pack("<%de" % len(flat), *flat)).decode("ascii")


def de_f16_b64(texto, dim=D):
    raw = base64.b64decode(texto)
    flat = struct.unpack("<%de" % (len(raw) // 2), raw)
    return [list(flat[i:i + dim]) for i in range(0, len(flat), dim)]


def carpeta_segura(palabra, maximo=80):
    """Igual que descargar_wikisigns.carpeta_segura (de ahí sale la glosa)."""
    limpio = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "", palabra).strip().rstrip(". ")
    limpio = re.sub(r"\s+", " ", limpio)
    return limpio[:maximo] or "sin_nombre"


def leer_entradas(ruta):
    """glosa -> (palabra con mayúsculas y acentos tal como la escribe la fuente, categoría)."""
    out = {}
    if not ruta or not os.path.exists(ruta):
        return out
    from glosa import a_glosa
    with open(ruta, encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            pal = (r.get("palabra") or "").strip()
            if pal:
                out.setdefault(a_glosa(carpeta_segura(pal)), (pal, (r.get("categoria") or "").strip()))
    return out


def glosas_de_la_app(ruta):
    if not ruta or not os.path.exists(ruta):
        return set()
    with open(ruta, encoding="utf-8") as f:
        pkg = json.load(f)
    return {p["gloss"] for p in pkg.get("plantillas", [])}


def curar(seq, cp):
    """(seq curada iso1, aspecto). Verifica que no cambie ninguna posición real de la muñeca."""
    seq = [list(map(float, fr)) for fr in seq]
    rep, _rell, _malos = cp.reparar(seq)
    aspecto = round(float(cp.estimar_aspecto(rep)[0]), 4)
    iso = cp.iso_secuencia(rep, aspecto)
    for t in range(len(seq)):
        for h in (0, 1):
            if seq[t][OFF_PRES[h]] >= 0.5:
                for k in range(3):
                    if abs(iso[t][OFF_LOC[h] + k] - seq[t][OFF_LOC[h] + k]) > 1e-9:
                        raise AssertionError("cambió la posición real de una muñeca (no debe pasar)")
        for c in range(24):
            if abs(iso[t][c] - seq[t][c]) > 1e-9:
                raise AssertionError("cambió el cuerpo (no debe pasar)")
    return iso, aspecto


def construir(filas, reglas, evaluar, existentes, entradas, minimo_manos, incluir_existentes, cp):
    """filas: dicts con gloss, espanol, sign_id, calidad, uri, seq. Devuelve (plantillas, reporte)."""
    reporte = []
    por_gloss = {}
    for f in filas:
        f["manos"] = fraccion_con_mano(f["seq"])
        motivo = ""
        v = evaluar(reglas, f["gloss"], f["espanol"]) if reglas is not None else None
        if v and v[0] in ("bloquear", "revisar"):
            motivo = f"{v[0]} ({v[1]})"
        elif f["manos"] < minimo_manos:
            motivo = f"poca mano ({f['manos']:.0%})"
        elif not incluir_existentes and f["gloss"] in existentes:
            motivo = "la app ya tiene esta seña"
        elif len(f["seq"]) != T or any(len(fr) != D for fr in f["seq"]):
            motivo = "tamaño raro"
        f["motivo"] = motivo
        if not motivo:
            por_gloss.setdefault(f["gloss"], []).append(f)
        reporte.append(f)
    plantillas = []
    for g in sorted(por_gloss):
        lista = sorted(por_gloss[g], key=lambda x: (-x["manos"], -x["calidad"], x["uri"]))
        for x in lista[1:]:
            x["motivo"] = "otra toma de la misma seña es mejor"
        mejor = lista[0]
        seq, aspecto = curar(mejor["seq"], cp)
        palabra, categoria = entradas.get(g, ("", ""))
        espanol = palabra or mejor["espanol"] or g.replace("_", " ").lower()
        mejor["motivo"] = "exportada"
        plantillas.append({
            "sign_id": mejor["sign_id"],
            "gloss": g,
            "espanol": espanol,
            "categoria": categoria,
            "aspecto": aspecto,
            "manos": round(mejor["manos"], 3),
            "seq_f16": a_f16_b64(seq),
        })
    return plantillas, reporte


def leer_base(conn, prefijo, norm_version):
    import sign_norm as sn
    cur = conn.cursor()
    cur.execute(
        """SELECT ss.id, s.id, s.gloss, s.espanol, ss.estado, ss.quality_score, ss.video_uri,
                  sl.data, sl.frame_dim
           FROM sign_samples ss
           JOIN signs s ON s.id = ss.sign_id
           JOIN sample_landmarks sl ON sl.sample_id = ss.id
           WHERE ss.video_uri LIKE %s AND ss.estado <> 'rechazada' AND sl.norm_version = %s""",
        (prefijo + "%", norm_version))
    filas = []
    for mid, sid, gloss, esp, estado, q, uri, blob, dim in cur.fetchall():
        try:
            calidad = float(q)
        except (TypeError, ValueError):
            calidad = 0.0
        filas.append({"id": str(mid), "sign_id": str(sid), "gloss": gloss, "espanol": esp or "",
                      "estado": estado, "calidad": calidad, "uri": uri or "",
                      "seq": sn.unpack_f16(bytes(blob), dim=int(dim))})
    return filas


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--prefijo", default="indiscapacidad:", help="video_uri de las muestras (indiscapacidad:)")
    ap.add_argument("--salida", default=SALIDA_DEFECTO)
    ap.add_argument("--plantillas-app", default=PLANTILLAS_APP,
                    help="plantillas.json de la app, para no repetir las señas que ya tiene")
    ap.add_argument("--incluir-existentes", action="store_true",
                    help="exporta también las señas que la app ya tiene (el Diccionario seguirá usando la curada)")
    ap.add_argument("--minimo-manos", type=float, default=0.6)
    ap.add_argument("--datos", default=DATOS_DEFECTO)
    ap.add_argument("--seco", action="store_true", help="no escribe nada")
    args = ap.parse_args()

    import moderar_senas as mod
    import sign_norm as sn
    import curar_plantillas as cp
    mod._consola_tolerante()

    fuente = FUENTES.get(args.prefijo, {"nombre": args.prefijo, "url": "", "entradas": ""})
    reglas = mod.cargar_reglas(mod.LISTA_DEFECTO)
    entradas = leer_entradas(fuente["entradas"])
    existentes = glosas_de_la_app(args.plantillas_app)
    log(f"fuente: {fuente['nombre']}\nla app ya tiene {len(existentes)} señas; {len(entradas)} palabras en entradas.csv")

    conn = mod.conectar()
    try:
        filas = leer_base(conn, args.prefijo, sn.NORM_VERSION)
    finally:
        conn.close()
    if not filas:
        raise SystemExit(f"no hay muestras con video_uri '{args.prefijo}...' en la base")
    log(f"{len(filas)} muestras en la base (sin las rechazadas)")

    plantillas, reporte = construir(filas, reglas, mod.evaluar, existentes, entradas,
                                    args.minimo_manos, args.incluir_existentes, cp)
    cuenta = {}
    for f in reporte:
        clave = f["motivo"].split(" (")[0]
        cuenta[clave] = cuenta.get(clave, 0) + 1
    for k, v in sorted(cuenta.items(), key=lambda kv: -kv[1]):
        log(f"  {v:5d}  {k}")

    paquete = {
        "norm_version": sn.NORM_VERSION, "t_frames": T, "frame_dim": D,
        "forma": "iso1", "uso": "aprendizaje", "codificacion": "f16le-base64",
        "fuente": fuente["nombre"], "url": fuente["url"],
        "generado": datetime.datetime.now().isoformat(timespec="seconds"),
        "n_plantillas": len(plantillas), "n_senas": len(plantillas),
        "plantillas": plantillas,
    }
    texto = json.dumps(paquete, ensure_ascii=False, separators=(",", ":"))
    # comprobación: lo que se escribe se vuelve a leer igual (float16)
    for p in plantillas[:5]:
        seq = de_f16_b64(p["seq_f16"])
        assert len(seq) == T and all(len(fr) == D for fr in seq)

    estampa = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    log(f"\n{len(plantillas)} señas para aprendizaje -> {len(texto.encode('utf-8')) / 1e6:.1f} MB")
    if args.seco:
        log("(--seco: no se escribió nada)")
        return 0
    os.makedirs(os.path.dirname(os.path.abspath(args.salida)), exist_ok=True)
    tmp = args.salida + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(texto)
    os.replace(tmp, args.salida)
    ruta_csv = os.path.join(args.datos, f"aprendizaje_{estampa}.csv")
    with open(ruta_csv, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["gloss", "espanol", "estado_base", "manos", "calidad", "video_uri", "resultado"])
        for r in sorted(reporte, key=lambda x: (x["gloss"], x["uri"])):
            w.writerow([r["gloss"], r["espanol"], r["estado"], f"{r['manos']:.2f}", r["calidad"], r["uri"],
                        r["motivo"]])
    log(f"escrito: {args.salida}\nreporte: {ruta_csv}")
    log("Siguiente: flutter run completo para que la app tome el archivo.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
