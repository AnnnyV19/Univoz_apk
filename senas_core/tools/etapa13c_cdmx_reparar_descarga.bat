@echo off
rem ETAPA 13c (v2, 19-oct): la descarga del Glosario CDMX falla con "This video is not available".
rem Causa vista en etapa13c_detalle.txt: yt-dlp 2026.08.19 (ya es el mas nuevo) NO tiene un motor de
rem JavaScript ("JS runtimes: none"); sin el, YouTube solo le contesta "UNPLAYABLE" a estos videos
rem (son "no listados"). yt-dlp usa Deno si esta instalado. Esto:
rem   1) instala Deno con pip si falta (paquete oficial "deno" de PyPI; winget no esta en esta PC),
rem   2) prueba UN video con detalle,  3) reintenta 6 videos.
cd /d "%~dp0.."
set PYTHONIOENCODING=utf-8
del /q datasets_lsm\etapa13c.ok datasets_lsm\etapa13c.fallo 2>nul
echo ===== ETAPA 13c: reparar la descarga del Glosario CDMX =====
echo.
echo [1/3] Motor de JavaScript para yt-dlp (Deno)
call :buscar_deno
where deno >nul 2>nul
if errorlevel 1 (
  echo Deno no esta instalado. Instalandolo con pip ^(paquete oficial "deno" de PyPI^)...
  python -m pip install -U deno > datasets_lsm\etapa13c_deno.txt 2>&1
  type datasets_lsm\etapa13c_deno.txt
  call :buscar_deno
)
where deno >nul 2>nul
if errorlevel 1 (
  echo.
  echo No encontre deno.exe despues de instalarlo.
  echo no-deno> datasets_lsm\etapa13c.fallo
  goto fin
)
deno --version
echo.
echo [2/3] Probar UN video con detalle (no lo baja, solo pregunta a YouTube)
python -m yt_dlp -v --skip-download "https://www.youtube.com/watch?v=AUCCh2ULoPU" > datasets_lsm\etapa13c_detalle.txt 2>&1
type datasets_lsm\etapa13c_detalle.txt
echo.
echo [3/3] Reintentar 6 videos de la lista
python tools\descargar_wikisigns.py --datos datasets_lsm\indiscapacidad_gdlsm --probar 6 --reintentar > datasets_lsm\etapa13c_descarga.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa13c_descarga.txt
if not "%ERR%"=="0" goto mal
findstr /c:" ok" datasets_lsm\etapa13c_descarga.txt >nul
if errorlevel 1 goto mal
echo listo> datasets_lsm\etapa13c.ok
echo.
echo ETAPA 13c: ya baja. Abre etapa13b_cdmx_todo.bat para bajar e importar todo.
goto fin
:mal
echo paro> datasets_lsm\etapa13c.fallo
echo.
echo ETAPA 13c: sigue sin bajar. Avisale a Claude: revisara datasets_lsm\etapa13c_detalle.txt
:fin
pause
goto :eof

:buscar_deno
for /f "delims=" %%D in ('python tools\buscar_deno.py 2^>nul') do set "PATH=%%D;%PATH%"
goto :eof
