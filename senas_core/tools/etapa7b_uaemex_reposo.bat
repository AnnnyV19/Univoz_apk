@echo off
rem ETAPA 7b: UAEMex con el importador v3 = SIN los cuadros de reposo (brazos colgando) al inicio y al final.
rem Por que: en estas fotos cada persona empieza y termina con los brazos colgando; con la v2 ~70 %% de los
rem cuadros de cada toma eran reposo (en lo ya aprobado, ~20 %%). La v3 los quita (sin cambiar ninguna altura)
rem y vuelve a armar las tomas desde los landmarks ya guardados: NO vuelve a correr MediaPipe (unos minutos).
rem Pasos: [1] las 1,840 muestras de la v2 pasan a "rechazada" (no se borra nada; se pueden revisar);
rem        [2] se reimporta todo como "pendiente" (sufijo .r1); [3] muestra lo que haria aprobar (--seco);
rem        [4] compara las alturas con lo ya aprobado (solo lectura).
rem plantillas.json NO cambia. Se puede correr varias veces. NO descarga nada.
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\etapa7b.ok datasets_lsm\etapa7b.fallo 2>nul
echo ===== ETAPA 7b: UAEMex (importador v3, sin cuadros de reposo) =====
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
echo [1/4] dejar como "rechazada" lo de la v2 (no se borra nada)
python tools\importar_uaemex.py --limpiar-anteriores
if errorlevel 1 goto mal
echo.
echo [2/4] todas las tomas con el recorte de reposo (a la base como pendientes)
python tools\importar_uaemex.py %ORIGEN%
if errorlevel 1 goto mal
echo.
echo [3/4] lo que haria aprobar 10 por palabra (--seco: no cambia nada)
python tools\aprobar_dataset.py --dataset uaemex --por-glosa 10 --existentes sumar --seco
if errorlevel 1 goto mal
echo.
echo [4/4] comparar alturas con lo ya aprobado (solo lectura)
python tools\comparar_uaemex_alturas.py > datasets_lsm\comparar_uaemex_alturas_v3.txt 2>&1
type datasets_lsm\comparar_uaemex_alturas_v3.txt
echo listo> datasets_lsm\etapa7b.ok
echo.
echo ETAPA 7b TERMINADA (plantillas.json sin cambios)
goto fin
:sinc
echo No encuentro el dataset: ni D:\UAEMEX, ni lo descomprimido en datasets_lsm, ni %ZIPD%.
:mal
echo paro> datasets_lsm\etapa7b.fallo
echo.
echo ETAPA 7b SE DETUVO: lee el mensaje de arriba y datasets_lsm\importacion.log
:fin
pause
