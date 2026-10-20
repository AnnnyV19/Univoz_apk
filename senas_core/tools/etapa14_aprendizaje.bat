@echo off
rem ETAPA 14: senas SOLO DE APRENDIZAJE (Glosario CDMX) -> D:\UNIVOZ_APK\univoz\assets\aprendizaje.json
rem No cambia la base (no aprueba ni rechaza) ni plantillas.json. La app las muestra en el Diccionario y el
rem avatar las hace; NO entran al reconocimiento.
cd /d "%~dp0.."
set PYTHONIOENCODING=utf-8
del /q datasets_lsm\etapa14.ok datasets_lsm\etapa14.fallo 2>nul
echo ===== ETAPA 14: senas de aprendizaje (Glosario CDMX) =====
python tools\exportar_aprendizaje.py > datasets_lsm\etapa14_aprendizaje.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa14_aprendizaje.txt
if not "%ERR%"=="0" goto mal
echo listo> datasets_lsm\etapa14.ok
echo ETAPA 14 TERMINADA
goto fin
:mal
echo paro> datasets_lsm\etapa14.fallo
echo ETAPA 14 SE DETUVO: lee datasets_lsm\etapa14_aprendizaje.txt
:fin
