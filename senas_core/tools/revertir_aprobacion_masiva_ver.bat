@echo off
rem SOLO MIRA la base: cuantas muestras aprobo la transaccion masiva (no cambia nada).
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\revertir_ver.ok datasets_lsm\revertir_ver.fallo 2>nul
set PYTHONIOENCODING=utf-8
python tools\revertir_aprobacion_masiva.py --xmin 4176 > datasets_lsm\revertir_ver.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\revertir_ver.txt
if not "%ERR%"=="0" goto mal
echo listo> datasets_lsm\revertir_ver.ok
goto fin
:mal
echo paro> datasets_lsm\revertir_ver.fallo
:fin
pause
