@echo off
rem ETAPA 3: ITESO-MX-100 (Mendeley g45jkzys4f). Usa los videos que ya tienes en D:\ITESO-MX-100
rem (una carpeta por sena); si no estan, baja los ~10.7 GB (reanuda si se corta).
rem Saca los landmarks (2 a 3 horas de MediaPipe). Todo entra 'pendiente'.
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\etapa3.ok datasets_lsm\etapa3.fallo 2>nul
echo ===== ETAPA 3: ITESO-MX-100 =====
set ITESO=D:\ITESO-MX-100
if exist "%ITESO%\Abrir" goto local
echo [1/3] descarga (no encuentro %ITESO%)
python tools\descargar_iteso.py
if errorlevel 1 goto mal
echo [2/3] prueba con 6 videos
python tools\importar_dataset_lsm.py --dataset iteso --probar 6
if errorlevel 1 goto mal
echo [3/3] todos los videos
python tools\importar_dataset_lsm.py --dataset iteso
if errorlevel 1 goto mal
goto bien
:local
echo [1/3] uso los videos ya descomprimidos en %ITESO% (no se baja nada)
echo [2/3] prueba con 6 videos
python tools\importar_dataset_lsm.py --dataset iteso --carpeta "%ITESO%" --probar 6
if errorlevel 1 goto mal
echo [3/3] todos los videos
python tools\importar_dataset_lsm.py --dataset iteso --carpeta "%ITESO%"
if errorlevel 1 goto mal
:bien
echo listo> datasets_lsm\etapa3.ok
echo.
echo ETAPA 3 TERMINADA
goto fin
:mal
echo paro> datasets_lsm\etapa3.fallo
echo.
echo ETAPA 3 SE DETUVO: lee el mensaje de arriba y datasets_lsm\importacion.log
:fin
pause
