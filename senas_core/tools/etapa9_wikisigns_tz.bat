@echo off
rem ETAPA 9: Wikisigns - baja los videos que faltan (T-Z y los pendientes; Lani dio permiso el 12-oct) y los importa a la base
rem como 'pendiente' (nada se aprueba solo; plantillas.json no cambia). Si se corta, vuelve a abrir este .bat: sigue donde se quedo.
rem Fuente: YouTube (videos de Wikisigns, CC BY-SA 4.0) con yt-dlp, a D:\univoz\senas_core\datasets_lsm\wikisigns_lsm\videos\<Palabra>\<id>.mp4
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\etapa9.ok datasets_lsm\etapa9.fallo 2>nul
set PYTHONIOENCODING=utf-8
echo ===== ETAPA 9: Wikisigns T-Z =====
echo.
echo [1/3] Descargar los videos que faltan (~202, unos 20 minutos)
python tools\descargar_wikisigns.py > datasets_lsm\etapa9_descarga.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa9_descarga.txt
if not "%ERR%"=="0" goto mal
echo.
echo [2/3] Importar a la base como pendientes (landmarks con MediaPipe)
python tools\importar_dataset_lsm.py --dataset wikisigns > datasets_lsm\etapa9_importar.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa9_importar.txt
if not "%ERR%"=="0" goto mal
echo.
echo [3/3] Conteo de la base
python tools\diag_base.py > datasets_lsm\etapa9_diag.txt 2>&1
type datasets_lsm\etapa9_diag.txt
echo listo> datasets_lsm\etapa9.ok
echo.
echo ETAPA 9 TERMINADA (plantillas.json sin cambios)
goto fin
:mal
echo paro> datasets_lsm\etapa9.fallo
echo.
echo ETAPA 9 SE DETUVO: lee el mensaje de arriba (datasets_lsm\etapa9_*.txt) y vuelve a abrirla para seguir
:fin
pause
