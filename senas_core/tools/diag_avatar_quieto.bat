@echo off
rem DIAGNOSTICO (solo lee): en que palabras el avatar casi no se mueve. No cambia nada.
rem Resultado: datasets_lsm\diag_avatar_quieto.txt y .csv
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\diag_avatar_quieto.ok 2>nul
set PYTHONIOENCODING=utf-8
python tools\diag_avatar_quieto.py > datasets_lsm\diag_avatar_quieto_consola.txt 2>&1
echo listo> datasets_lsm\diag_avatar_quieto.ok
echo Listo. Mira datasets_lsm\diag_avatar_quieto.txt
timeout /t 6
