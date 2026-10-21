@echo off
rem ETAPA 6: devuelve a plantillas.json las 300 senas de Wikisigns que tenias aprobadas el 9 de octubre
rem (la base las tenia como 'pendiente' y el export nuevo las habia quitado). Solo aprueba si el plan coincide
rem EXACTAMENTE con aquella tanda. Reversible: deja volver_a_pendiente_*.sql y respaldo del plantillas.json.
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\etapa6.ok datasets_lsm\etapa6.fallo 2>nul
set PYTHONIOENCODING=utf-8
echo ===== ETAPA 6: restaurar la tanda de 300 de Wikisigns =====
echo.
echo [1/3] Plan (sin cambios)
python tools\aprobar_dataset.py --dataset wikisigns --limite 300 --seco > datasets_lsm\etapa6_plan.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa6_plan.txt
if not "%ERR%"=="0" goto mal
echo.
echo [2/3] Comparar con la tanda del 9 de octubre
python tools\comparar_tanda.py datasets_lsm\etapa6_plan.txt datasets_lsm\aprobacion_20261009_100907.csv > datasets_lsm\etapa6_comparar.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa6_comparar.txt
if not "%ERR%"=="0" goto mal
echo.
echo [3/3] Aprobar y regenerar plantillas.json
python tools\aprobar_dataset.py --dataset wikisigns --limite 300 > datasets_lsm\etapa6_aprobar.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa6_aprobar.txt
if not "%ERR%"=="0" goto mal
echo listo> datasets_lsm\etapa6.ok
echo.
echo ETAPA 6 TERMINADA
goto fin
:mal
echo paro> datasets_lsm\etapa6.fallo
echo.
echo ETAPA 6 SE DETUVO: no se cambio nada o se detuvo a medias; lee el mensaje de arriba (datasets_lsm\etapa6_*.txt)
:fin
pause
