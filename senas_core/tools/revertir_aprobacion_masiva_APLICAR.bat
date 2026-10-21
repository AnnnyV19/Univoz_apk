@echo off
rem APLICA el revert: vuelve a 'pendiente' las 4,409 muestras que aprobo la transaccion masiva (ITESO, Wikisigns y letras)
rem para que la base coincida con tu plantillas.json (1,268 aprobadas). Guarda datasets_lsm\reaprobar_masiva_*.sql
rem (con eso las vuelves a aprobar) y se deshace solo si algo no cuadra. NO exporta ni toca plantillas.json.
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\revertir_aplicar.ok datasets_lsm\revertir_aplicar.fallo 2>nul
set PYTHONIOENCODING=utf-8
python tools\revertir_aprobacion_masiva.py --xmin 4176 --aplicar > datasets_lsm\revertir_aplicar.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\revertir_aplicar.txt
if not "%ERR%"=="0" goto mal
echo listo> datasets_lsm\revertir_aplicar.ok
goto fin
:mal
echo paro> datasets_lsm\revertir_aplicar.fallo
:fin
pause
