@echo off
rem ETAPA 7c: lo que aprobaria de UAEMex con filtros de ALTURA (solo lectura: --seco, no cambia nada).
rem Por que: aun recortado el reposo, muchas tomas de UAEMex tienen la mano "colgando" casi todo el tiempo
rem (la mano no se detecta cuando sube a la cara, tapada por el recuadro borroso) y las tomas en modo
rem "solo mano" tienen una altura de muneca SINTETICA. Regla del proyecto: no normalizar ni mover alturas;
rem entonces lo que no sirve se OMITE, no se corrige.
rem   A = solo quita las tomas "solo mano"
rem   B = A + la muneca (percentil 90) debe subir a -0.5 anchos de hombro o mas + brazo colgando <= 50 %%
rem   C = A + minimo -0.3 + brazo colgando <= 40 %%  (mas estricto)
rem Resultados: datasets_lsm\etapa7c_planA.txt / planB / planC (y un CSV por plan en datasets_lsm).
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\etapa7c.ok datasets_lsm\etapa7c.fallo 2>nul
echo ===== ETAPA 7c: planes de aprobacion UAEMex con filtros de altura (--seco) =====
echo.
echo [1/3] plan A: sin las tomas "solo mano"
python tools\aprobar_dataset.py --dataset uaemex --por-glosa 10 --existentes sumar --sin-solo-mano --seco > datasets_lsm\etapa7c_planA.txt 2>&1
if errorlevel 1 goto mal
echo [2/3] plan B: A + muneca sube a -0.5 o mas + reposo max 50 %%
python tools\aprobar_dataset.py --dataset uaemex --por-glosa 10 --existentes sumar --sin-solo-mano --pico-minimo -0.5 --reposo-maximo 0.5 --seco > datasets_lsm\etapa7c_planB.txt 2>&1
if errorlevel 1 goto mal
echo [3/3] plan C: A + muneca sube a -0.3 o mas + reposo max 40 %%
python tools\aprobar_dataset.py --dataset uaemex --por-glosa 10 --existentes sumar --sin-solo-mano --pico-minimo -0.3 --reposo-maximo 0.4 --seco > datasets_lsm\etapa7c_planC.txt 2>&1
if errorlevel 1 goto mal
echo listo> datasets_lsm\etapa7c.ok
echo.
echo ETAPA 7c TERMINADA (no se cambio nada; plantillas.json sin cambios)
goto fin
:mal
echo paro> datasets_lsm\etapa7c.fallo
echo.
echo ETAPA 7c SE DETUVO: mira datasets_lsm\etapa7c_plan*.txt
:fin
pause
