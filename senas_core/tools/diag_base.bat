@echo off
rem SOLO LEE la base: cuenta muestras por estado y origen (no cambia nada).
cd /d "%~dp0.."
set PYTHONIOENCODING=utf-8
python tools\diag_base.py > datasets_lsm\diag_base.txt 2>&1
type datasets_lsm\diag_base.txt
echo listo> datasets_lsm\diag_base.ok
pause
