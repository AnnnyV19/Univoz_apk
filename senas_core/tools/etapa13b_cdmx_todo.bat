@echo off
rem ETAPA 13b: Glosario Digital de LSM de INDISCAPACIDAD CDMX - TODO (1,050 videos, ~1.5 h de descarga).
rem Si se corta, vuelve a abrir este .bat: sigue donde se quedo. Todo entra 'pendiente'; plantillas.json NO cambia.
cd /d "%~dp0.."
del /q datasets_lsm\etapa13b.ok datasets_lsm\etapa13b.fallo 2>nul
set PYTHONIOENCODING=utf-8
rem yt-dlp necesita Deno (motor de JavaScript) para estos videos; ver etapa13c
if exist "%LOCALAPPDATA%\Microsoft\WinGet\Links\deno.exe" set "PATH=%LOCALAPPDATA%\Microsoft\WinGet\Links;%PATH%"
if exist "%USERPROFILE%\.deno\bin\deno.exe" set "PATH=%USERPROFILE%\.deno\bin;%PATH%"
for /f "delims=" %%D in ('python tools\buscar_deno.py 2^>nul') do set "PATH=%%D;%PATH%"
echo ===== ETAPA 13b: Glosario CDMX completo =====
echo.
echo [1/3] Bajar los videos que faltan
python tools\descargar_wikisigns.py --datos datasets_lsm\indiscapacidad_gdlsm --reintentar > datasets_lsm\etapa13b_descarga.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa13b_descarga.txt
if not "%ERR%"=="0" goto mal
echo.
echo [2/3] Landmarks e importar como pendientes
python tools\importar_dataset_lsm.py --dataset cdmx > datasets_lsm\etapa13b_importar.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa13b_importar.txt
if not "%ERR%"=="0" goto mal
echo.
echo [3/3] Conteo de la base
python tools\diag_base.py > datasets_lsm\etapa13b_diag.txt 2>&1
type datasets_lsm\etapa13b_diag.txt
echo listo> datasets_lsm\etapa13b.ok
echo.
echo ETAPA 13b TERMINADA (plantillas.json sin cambios; falta aprobar como "solo aprendizaje")
goto fin
:mal
echo paro> datasets_lsm\etapa13b.fallo
echo.
echo ETAPA 13b SE DETUVO: lee el mensaje de arriba (datasets_lsm\etapa13b_*.txt) y vuelve a abrirla para seguir
:fin
pause
