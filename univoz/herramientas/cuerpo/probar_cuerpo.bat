@echo off
rem Prueba del separador de cuerpo del avatar (requiere Node.js; es opcional, no afecta a la app).
cd /d "%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo Falta Node.js: esta prueba es opcional. Instala Node 18 o mayor desde nodejs.org y vuelve a correrla.
  exit /b 2
)
set HTML=..\..\assets\avatar_viewer\index.html
echo [1/5] El modulo SeparadorCuerpo del visor contra la referencia en Python...
node prueba_cuerpo.js %HTML% casos_cuerpo.json
if errorlevel 1 goto fallo
echo [2/5] resolverBrazo real del visor (con THREE de mentira): altura de muneca y largo de huesos...
node prueba_visor.js %HTML% casos_visor.json - 6
if errorlevel 1 goto fallo
echo [3/5] El modulo SeparadorManos del visor contra la referencia en Python...
node prueba_manos.js %HTML% casos_par.json
if errorlevel 1 goto fallo
echo [4/5] planificarManos + resolverBrazo reales con las dos manos...
node prueba_visor_manos.js %HTML% casos_visor_pares.json - 6
if errorlevel 1 goto fallo
echo [5/5] Frase: varias senas seguidas...
node prueba_frase.js %HTML% frase_prueba.json
if errorlevel 1 goto fallo
echo.
echo TODO OK
exit /b 0
:fallo
echo.
echo FALLO: revisa el mensaje de arriba.
exit /b 1
