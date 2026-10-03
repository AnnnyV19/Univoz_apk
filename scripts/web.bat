@echo off
chcp 65001 >nul
REM ============================================================
REM  Univoz en el navegador (Windows). Equivale a:
REM      ./scripts/univoz.sh web
REM  Sirve el visor en http://127.0.0.1:8080 y guarda cada sesion
REM  de camara en senas_core\sesiones\ (solo puntos, nunca video).
REM  Opcional: scripts\web.bat 9000   (otro puerto)
REM  Cerrar esta ventana (o Ctrl+C) apaga el servidor.
REM ============================================================
setlocal
set PUERTO=%1
if "%PUERTO%"=="" set PUERTO=8080

where py >nul 2>&1 && (set "PY=py -3") || (set "PY=python")
%PY% --version >nul 2>&1 || (
  echo No encontre Python. Instala Python 3 desde https://www.python.org/downloads/
  echo y marca "Add python.exe to PATH" durante la instalacion.
  pause
  exit /b 1
)

cd /d "%~dp0..\senas_core"
set "URL=http://127.0.0.1:%PUERTO%/assets/avatar_viewer/index.html?standalone=1"
echo Visor: %URL%
start "" "%URL%"
%PY% tools\servidor_visor.py --port %PUERTO% --bind 127.0.0.1
endlocal
