@echo off
rem SOLO LEE: cuenta grabaciones distintas por sena (plantillas.json + pendientes de la base) y escribe un CSV. No cambia nada.
cd /d "%~dp0.."
set PYTHONIOENCODING=utf-8
if exist datasets_lsm\cobertura_total.ok del datasets_lsm\cobertura_total.ok
if exist datasets_lsm\cobertura_total.fallo del datasets_lsm\cobertura_total.fallo
python tools\cobertura_muestras.py --base --objetivo 10 --csv datasets_lsm\cobertura_total.csv > datasets_lsm\cobertura_total.txt 2>&1
if errorlevel 1 (
  echo fallo> datasets_lsm\cobertura_total.fallo
) else (
  echo listo> datasets_lsm\cobertura_total.ok
)
