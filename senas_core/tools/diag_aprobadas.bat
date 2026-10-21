@echo off
rem SOLO LEE la base: averigua cuando y como quedaron aprobadas las muestras (no cambia nada).
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\diag_aprobadas.ok datasets_lsm\diag_aprobadas.fallo 2>nul
set PYTHONIOENCODING=utf-8
python tools\diag_aprobadas.py > datasets_lsm\diag_aprobadas.txt 2>&1
if errorlevel 1 goto mal
type datasets_lsm\diag_aprobadas.txt
echo listo> datasets_lsm\diag_aprobadas.ok
goto fin
:mal
type datasets_lsm\diag_aprobadas.txt
echo paro> datasets_lsm\diag_aprobadas.fallo
:fin
pause
