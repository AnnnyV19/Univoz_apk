@echo off
rem ETAPA 7 (v2): UAEMex, 249 PALABRAS (Mendeley 6rj76z6y3n, CC BY 4.0), con el importador v2.
rem La etapa 7 original entendio mal las carpetas (metio las 249 palabras como UNA). Este script:
rem   - lee la estructura real:  palabra (001-249) \ persona (PP+palabra) \ fotos
rem   - pasa los nombres del ingles al espanol de la app (tools\clases_uaemex_es.csv)
rem   - deja "rechazada" la importacion equivocada (no borra nada) y reimporta todo como "pendiente"
rem plantillas.json NO cambia: aprobar es otro paso (aqui solo se muestra, con --seco, lo que haria).
rem Se puede correr varias veces: lo que ya esta importado no se repite. NO descarga nada.
rem El dataset ya esta descargado y descomprimido: usa D:\UAEMEX si existe; si no, lo que ya se
rem descomprimio dentro de datasets_lsm; si no, D:\Mexican sign language dataset.zip.
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\etapa7.ok datasets_lsm\etapa7.fallo 2>nul
echo ===== ETAPA 7 (v2): UAEMex 249 palabras (importador v2) =====
set UAE=D:\UAEMEX
set ZIPD=D:\Mexican sign language dataset.zip
set EXTR=datasets_lsm\mendeley_6rj76z6y3n\imagenes
if exist "%UAE%" goto hayc
if exist "%EXTR%\.extraido" goto hayx
if exist "%ZIPD%" goto hayz
goto sinc
:hayc
set ORIGEN=--carpeta "%UAE%"
for %%Z in ("%UAE%\*.zip") do set ORIGEN=--zip "%%Z"
goto sigue
:hayx
set ORIGEN=--carpeta "%EXTR%"
goto sigue
:hayz
set ORIGEN=--zip "%ZIPD%"
:sigue
echo origen: %ORIGEN%
echo.
echo [1/5] que entiendo de la estructura (no toca la base)
python tools\importar_uaemex.py %ORIGEN% --listar
if errorlevel 1 goto mal
echo.
echo [2/5] dejar como "rechazada" la importacion equivocada de antes (no se borra nada)
python tools\importar_uaemex.py --limpiar-v1
if errorlevel 1 goto mal
echo.
echo [3/5] prueba con 10 tomas (no toca la base; si sale mal, igual sigue)
python tools\importar_uaemex.py %ORIGEN% --probar 10
echo.
echo [4/5] todas las tomas (a la base como pendientes; tarda un rato)
python tools\importar_uaemex.py %ORIGEN%
if errorlevel 1 goto mal
echo.
echo [5/5] lo que haria aprobar 10 por palabra (--seco: no cambia nada)
python tools\aprobar_dataset.py --dataset uaemex --por-glosa 10 --existentes sumar --seco
if errorlevel 1 goto mal
echo listo> datasets_lsm\etapa7.ok
echo.
echo ETAPA 7 (v2) TERMINADA (plantillas.json sin cambios)
goto fin
:sinc
echo No encuentro D:\UAEMEX, ni lo ya descomprimido, ni "%ZIPD%". Pon el zip de Mendeley en esa ruta.
:mal
echo paro> datasets_lsm\etapa7.fallo
echo.
echo ETAPA 7 (v2) SE DETUVO: lee el mensaje de arriba y datasets_lsm\importacion.log
:fin
pause
