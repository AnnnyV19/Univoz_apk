@echo off
rem ETAPA 13a: Glosario Digital de LSM de INDISCAPACIDAD CDMX - PRUEBA con 6 videos.
rem Baja 6 videos de YouTube y los importa a la base como 'pendiente' (plantillas.json NO cambia).
rem Autorizacion: INDISCAPACIDAD es cliente de UNIVOZ (Lani, 14-oct-2026). Uso: solo aprendizaje (avatar), no reconocimiento.
cd /d "%~dp0.."
if not exist datasets_lsm\indiscapacidad_gdlsm\entradas.csv (
  echo Falta datasets_lsm\indiscapacidad_gdlsm\entradas.csv
  goto mal
)
del /q datasets_lsm\etapa13a.ok datasets_lsm\etapa13a.fallo 2>nul
set PYTHONIOENCODING=utf-8
echo ===== ETAPA 13a: Glosario CDMX, prueba con 6 videos =====
echo.
echo [1/3] Cuantos videos hay (no baja nada)
python tools\descargar_wikisigns.py --datos datasets_lsm\indiscapacidad_gdlsm --seco > datasets_lsm\etapa13a_seco.txt 2>&1
type datasets_lsm\etapa13a_seco.txt
echo.
echo [2/3] Bajar 6 videos repartidos
python tools\descargar_wikisigns.py --datos datasets_lsm\indiscapacidad_gdlsm --probar 6 > datasets_lsm\etapa13a_descarga.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa13a_descarga.txt
if not "%ERR%"=="0" goto mal
echo.
echo [3/3] Landmarks e importar como pendientes (solo los 6)
python tools\importar_dataset_lsm.py --dataset cdmx --probar 6 > datasets_lsm\etapa13a_importar.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa13a_importar.txt
if not "%ERR%"=="0" goto mal
echo listo> datasets_lsm\etapa13a.ok
echo.
echo ETAPA 13a TERMINADA. Si salio bien, abre etapa13b_cdmx_todo.bat
goto fin
:mal
echo paro> datasets_lsm\etapa13a.fallo
echo.
echo ETAPA 13a SE DETUVO: lee el mensaje de arriba (datasets_lsm\etapa13a_*.txt)
:fin
pause
