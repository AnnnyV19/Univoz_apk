@echo off
rem ETAPA 5: APRUEBA las letras de CICESE (dinamicas J K N~ Q X Z y estaticas) hasta 10 grabaciones DISTINTAS por letra
rem y regenera plantillas.json (con respaldo en D:\UNIVOZ_APK\_respaldo_antes_de_dataset).
rem Es reversible: cada tanda deja datasets_lsm\volver_a_pendiente_*.sql y el respaldo del plantillas.json anterior.
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\etapa5.ok datasets_lsm\etapa5.fallo 2>nul
set PYTHONIOENCODING=utf-8
echo ===== ETAPA 5: aprobar letras (10 por letra) =====
echo.
echo [1/4] Plan de las dinamicas (sin cambios)
python tools\aprobar_dataset.py --dataset alfabeto --por-glosa 10 --existentes sumar --seco > datasets_lsm\etapa5_plan_dinamicas.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa5_plan_dinamicas.txt
if not "%ERR%"=="0" goto mal
echo.
echo [2/4] Plan de las estaticas (sin cambios)
python tools\aprobar_dataset.py --dataset alfabeto_estatico --por-glosa 10 --existentes sumar --seco > datasets_lsm\etapa5_plan_estaticas.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa5_plan_estaticas.txt
if not "%ERR%"=="0" goto mal
echo.
echo [3/4] Aprobar dinamicas (aun sin exportar)
python tools\aprobar_dataset.py --dataset alfabeto --por-glosa 10 --existentes sumar --sin-exportar > datasets_lsm\etapa5_aprobar_dinamicas.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa5_aprobar_dinamicas.txt
if not "%ERR%"=="0" goto mal
echo.
echo [4/4] Aprobar estaticas y regenerar plantillas.json
python tools\aprobar_dataset.py --dataset alfabeto_estatico --por-glosa 10 --existentes sumar > datasets_lsm\etapa5_aprobar_estaticas.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa5_aprobar_estaticas.txt
if not "%ERR%"=="0" goto mal
python tools\cobertura_muestras.py --base --solo-letras --csv datasets_lsm\cobertura_letras_despues.csv > datasets_lsm\etapa5_cobertura_letras.txt 2>&1
type datasets_lsm\etapa5_cobertura_letras.txt
echo listo> datasets_lsm\etapa5.ok
echo.
echo ETAPA 5 TERMINADA
goto fin
:mal
echo paro> datasets_lsm\etapa5.fallo
echo.
echo ETAPA 5 SE DETUVO: lee el mensaje de arriba (datasets_lsm\etapa5_*.txt)
:fin
pause
