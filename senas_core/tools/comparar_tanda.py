#!/usr/bin/env python3
"""SOLO LEE. Compara el plan de una tanda (--seco) con una tanda ya hecha:
    python tools\\comparar_tanda.py <salida_del_plan.txt> <aprobacion_..._csv_de_la_tanda_anterior>
Sale con 0 si las muestras que el plan aprobaria son las MISMAS (video_uri) que aprobo la tanda anterior
(diferencia maxima 3); con 1 si no."""
import csv
import re
import sys


def aprobar(ruta):
    with open(ruta, encoding="utf-8-sig", newline="") as fh:
        return {r["video_uri"] for r in csv.DictReader(fh) if r.get("decision") == "aprobar"}


def main():
    plan_txt, csv_viejo = sys.argv[1], sys.argv[2]
    with open(plan_txt, encoding="utf-8", errors="replace") as fh:
        m = re.search(r"detalle de cada toma:\s*(.+\.csv)", fh.read())
    if not m:
        print("no encontre el CSV del plan en", plan_txt)
        return 1
    nuevo, viejo = aprobar(m.group(1).strip()), aprobar(csv_viejo)
    comunes = nuevo & viejo
    dif = len(nuevo ^ viejo)
    print(f"plan: {len(nuevo)} muestras | tanda anterior: {len(viejo)} | iguales: {len(comunes)} | diferencia: {dif}")
    if not viejo or dif > 3:
        print("EL PLAN NO COINCIDE con la tanda anterior: no se aprueba nada.")
        return 1
    print("el plan coincide con la tanda del 9 de octubre.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
