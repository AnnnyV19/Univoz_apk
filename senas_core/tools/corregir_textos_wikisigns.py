#!/usr/bin/env python3
"""Corrige el texto en espanol (signs.espanol) de senas de Wikisigns que quedaron sin acento o cortadas
(p. ej. "timida" -> "tímida", "alvaro obregon (deleg. méx" -> "álvaro obregón (deleg. méx.)").

SEGURO por diseno:
  - solo toca una sena si su texto actual es EXACTAMENTE el que aparece en la columna "antes" de la tabla de abajo
    (si ya lo cambiaste tu o es otro, la salta y lo dice);
  - no toca estados (pendiente/aprobada/rechazada), muestras, landmarks ni plantillas.json;
  - por defecto solo MUESTRA lo que haria; con --aplicar escribe, en una transaccion, y deja
    datasets_lsm/deshacer_textos_<fecha>.sql para volver al texto anterior.

Ojo: importar_dataset_lsm.py usa upsert_sign (ON CONFLICT (gloss) DO UPDATE SET espanol), asi que si
vuelves a importar Wikisigns el texto de esas senas se vuelve a sobrescribir con el de la importacion.

El texto nuevo llega a la app solo cuando se vuelva a exportar plantillas.json (hoy no se exporta).

USO (desde senas_core)
    python tools/corregir_textos_wikisigns.py            # solo muestra
    python tools/corregir_textos_wikisigns.py --aplicar  # escribe
"""

import argparse
import datetime
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import moderar_senas as mod  # noqa: E402
from moderar_senas import log  # noqa: E402

# (glosa, texto actual esperado, texto corregido). Solo lo que es seguro: acentos faltantes en palabras comunes,
# nombres de lugares, y textos cortados por un parentesis o un punto del titulo del video.
CORRECCIONES = [
    ("TIMIDA", "timida", "tímida"),
    ("TIMIDO", "timido", "tímido"),
    ("TONTERIAS", "tonterias", "tonterías"),
    ("TRAICION", "traicion", "traición"),
    ("TRAILER", "trailer", "tráiler"),
    ("TUXTLA_GUTIERREZ", "tuxtla gutierrez", "tuxtla gutiérrez"),
    ("ULTIMAMENTE", "ultimamente", "últimamente"),
    ("ULTIMO", "ultimo", "último"),
    ("UNAHORA", "una-hora", "una hora"),
    ("VACIO", "vacio", "vacío"),
    ("VEHICULO", "vehiculo", "vehículo"),
    ("VERGUENZA", "verguenza", "vergüenza"),
    ("VENUSTIANO_CARRANZA_DELEGACION", "venustiano carranza (delegación", "venustiano carranza (delegación)"),
    ("VICEPRESIDENTE", "vice-presidente", "vicepresidente"),
    ("TLAHUAC", "tlahuác", "tláhuac"),
    ("TLALPAN", "tlalpán", "tlalpan"),
    ("YO_SI_PUEDO", "yo si puedo", "yo sí puedo"),
    ("ALVARO_OBREGON_DELEG_MEX", "alvaro obregon (deleg. méx", "álvaro obregón (deleg. méx.)"),
    ("DF", "d.f.)", "d.f."),
    ("POLITICA", "politica", "política"),
    ("DIALOGO", "dialogo", "diálogo"),
    ("INCLUSION", "inclusion", "inclusión"),
    ("CANCUN", "cancun", "cancún"),
    ("JICAMA", "jicama", "jícama"),
    ("PETROLEO", "petroleo", "petróleo"),
    ("LAZARO_CARDENAS", "lazaro cardenas", "lázaro cárdenas"),
    ("CD_OBREGON", "cd. obregon", "cd. obregón"),
]


def sql_texto(s):
    return "'" + s.replace("'", "''") + "'"


def main():
    mod._consola_tolerante()
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--aplicar", action="store_true", help="escribe los cambios (sin esto solo se muestran)")
    ap.add_argument("--datos", default=mod.DATOS_DEFECTO, help="donde dejar el .sql para deshacer")
    args = ap.parse_args()

    conn = mod.conectar()
    try:
        cur = conn.cursor()
        cambios, saltadas = [], []
        for gloss, antes, despues in CORRECCIONES:
            cur.execute("SELECT id, espanol FROM signs WHERE gloss = %s", (gloss,))
            fila = cur.fetchone()
            if not fila:
                saltadas.append((gloss, "no esta en la base"))
            elif (fila[1] or "") == despues:
                saltadas.append((gloss, "ya tiene el texto corregido"))
            elif (fila[1] or "") != antes:
                saltadas.append((gloss, f"texto distinto al esperado (ahora: {fila[1]!r}); no se toca"))
            else:
                cambios.append((str(fila[0]), gloss, antes, despues))

        log(f"correcciones de texto: {len(cambios)} por hacer, {len(saltadas)} saltadas"
            + ("" if args.aplicar else "   (sin --aplicar: no se cambia nada)"))
        for _id, gloss, antes, despues in cambios:
            log(f"  {gloss:32s} {antes!r} -> {despues!r}")
        for gloss, motivo in saltadas:
            log(f"  (salta) {gloss}: {motivo}")

        if not args.aplicar:
            log("\n(no se cambio nada; para escribir: --aplicar)")
            return 0
        if not cambios:
            log("\nnada que cambiar")
            return 0

        estampa = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        os.makedirs(args.datos, exist_ok=True)
        ruta = os.path.join(args.datos, f"deshacer_textos_{estampa}.sql")
        with open(ruta, "w", encoding="utf-8") as fh:
            fh.write(f"-- Deshace corregir_textos_wikisigns.py del {estampa}: devuelve el texto anterior.\n\n")
            for sid, gloss, antes, _despues in cambios:
                fh.write(f"UPDATE signs SET espanol = {sql_texto(antes)} WHERE id = '{sid}';  -- {gloss}\n")
        try:
            for sid, gloss, antes, despues in cambios:
                cur.execute("UPDATE signs SET espanol = %s WHERE id = %s AND espanol = %s", (despues, sid, antes))
                if cur.rowcount != 1:
                    raise RuntimeError(f"{gloss}: se esperaba cambiar 1 fila y cambio {cur.rowcount}")
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        log(f"\nCORREGIDAS {len(cambios)} senas. Para deshacer: {ruta}")
        log("(no se toco ningun estado ni plantillas.json)")
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("\ninterrumpido")
        sys.exit(130)
