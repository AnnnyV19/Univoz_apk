@echo off
rem Compara las ALTURAS de muneca de las tomas de UAEMex con lo ya aprobado de otros origenes.
rem SOLO LEE la base: no aprueba nada y plantillas.json no cambia. Resultado en datasets_lsm\comparar_uaemex_alturas.txt/.csv
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\comparar_uaemex.ok datasets_lsm\comparar_uaemex.fallo 2>nul
echo ===== Comparar alturas UAEMex (solo lectura) =====
python tools\comparar_uaemex_alturas.py > datasets_lsm\comparar_uaemex_alturas.txt 2>&1
if errorlevel 1 goto mal
type datasets_lsm\comparar_uaemex_alturas.txt
echo listo> datasets_lsm\comparar_uaemex.ok
goto fin
:mal
type datasets_lsm\comparar_uaemex_alturas.txt
echo paro> datasets_lsm\comparar_uaemex.fallo
echo.
echo SE DETUVO: lee el mensaje de arriba.
:fin
pause
