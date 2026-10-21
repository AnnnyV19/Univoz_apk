@echo off
rem ETAPA 8: UAEMex PLAN A (Lani lo eligio el 12-oct): aprueba hasta 10 grabaciones por sena de UAEMex, sin las tomas
rem "solo mano" (altura sintetica). NO exporta ni toca plantillas.json (los ~51 MB actuales se prueban primero en el telefono).
rem Reversible: deja datasets_lsm\volver_a_pendiente_*.sql. Primero muestra el plan (--seco), luego aprueba, luego cuenta.
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\etapa8.ok datasets_lsm\etapa8.fallo 2>nul
set PYTHONIOENCODING=utf-8
echo ===== ETAPA 8: UAEMex plan A =====
echo.
echo [1/4] Plan (sin cambios)
python tools\aprobar_dataset.py --dataset uaemex --por-glosa 10 --existentes sumar --sin-solo-mano --seco > datasets_lsm\etapa8_planA_seco.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa8_planA_seco.txt
if not "%ERR%"=="0" goto mal
echo.
echo [2/4] Aprobar (sin exportar plantillas.json)
python tools\aprobar_dataset.py --dataset uaemex --por-glosa 10 --existentes sumar --sin-solo-mano --sin-exportar > datasets_lsm\etapa8_planA_aprobar.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa8_planA_aprobar.txt
if not "%ERR%"=="0" goto mal
echo.
echo [3/4] Conteo de la base despues
python tools\diag_base.py > datasets_lsm\etapa8_diag.txt 2>&1
type datasets_lsm\etapa8_diag.txt
echo.
echo [4/4] Wikisigns: cuantos videos faltan por bajar (solo cuenta, no baja nada)
python tools\descargar_wikisigns.py --seco > datasets_lsm\etapa9_wikisigns_seco.txt 2>&1
type datasets_lsm\etapa9_wikisigns_seco.txt
echo listo> datasets_lsm\etapa8.ok
echo.
echo ETAPA 8 TERMINADA (plantillas.json sin cambios)
goto fin
:mal
echo paro> datasets_lsm\etapa8.fallo
echo.
echo ETAPA 8 SE DETUVO: lee el mensaje de arriba (datasets_lsm\etapa8_*.txt)
:fin
pause
