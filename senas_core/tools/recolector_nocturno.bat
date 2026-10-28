@echo off
chcp 65001 >nul
rem ============================================================
rem  Recolector nocturno de muestras de señas (tools/recolector_nocturno.py).
rem  Busca videos nuevos con licencia abierta para las señas con menos de 10
rem  muestras, saca landmarks, los guarda como pendientes y aprueba solo los
rem  que el reconocedor confirma. Log: datasets_lsm\recolector\ultima_noche.txt
rem  Lo corre la tarea programada (registrar_recolector.bat) o a mano.
rem ============================================================
setlocal
cd /d "%~dp0.."
if not exist datasets_lsm\recolector mkdir datasets_lsm\recolector
set "PY=python"
where py >nul 2>&1 && set "PY=py -3"
%PY% tools\recolector_nocturno.py --auto-aprobar > datasets_lsm\recolector\ultima_noche.txt 2>&1
endlocal
