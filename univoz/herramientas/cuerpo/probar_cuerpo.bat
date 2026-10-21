@echo off
rem Pruebas del separador de cuerpo, de manos, frases y reproduccion del avatar
rem (requiere Node.js; no afecta a la app). Ahora son pruebas normales de
rem senas_core\tools\rig-tests (ver LEEME.md y docs\17-integracion-app-limpia.md).
cd /d "%~dp0\..\..\..\senas_core\tools\rig-tests"
where node >nul 2>nul
if errorlevel 1 (
  echo Falta Node.js: esta prueba es opcional. Instala Node 18 o mayor desde nodejs.org y vuelve a correrla.
  exit /b 2
)
if not exist node_modules\three (
  echo Instalando dependencias de las pruebas...
  call npm ci
  if errorlevel 1 goto fallo
)
call npm test
if errorlevel 1 goto fallo
echo.
echo TODO OK
exit /b 0
:fallo
echo.
echo FALLO: revisa el mensaje de arriba.
exit /b 1
