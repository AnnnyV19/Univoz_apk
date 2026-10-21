@echo off
rem ETAPA 1: letras DINAMICAS de CICESE (J, K, N con tilde, Q, X, Z), Zenodo 14689869, ~2.2 GB.
rem Prueba con 6 videos y, si sale bien, sigue con todos. Todo entra 'pendiente'; plantillas.json no cambia.
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\etapa1.ok datasets_lsm\etapa1.fallo 2>nul
echo ===== ETAPA 1: letras dinamicas =====
echo [1/2] prueba con 6 videos
python tools\importar_dataset_lsm.py --dataset alfabeto --probar 6
if errorlevel 1 goto mal
echo [2/2] todos los videos
python tools\importar_dataset_lsm.py --dataset alfabeto
if errorlevel 1 goto mal
echo listo> datasets_lsm\etapa1.ok
echo.
echo ETAPA 1 TERMINADA
goto fin
:mal
echo paro> datasets_lsm\etapa1.fallo
echo.
echo ETAPA 1 SE DETUVO: lee el mensaje de arriba y datasets_lsm\importacion.log
:fin
pause
