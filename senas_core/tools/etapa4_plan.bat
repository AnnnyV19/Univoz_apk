@echo off
rem ETAPA 4: SOLO MIRA. Cobertura actual y plan de --por-glosa 10 (--seco): no aprueba ni exporta nada.
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\etapa4.ok datasets_lsm\etapa4.fallo 2>nul
set PYTHONIOENCODING=utf-8
echo ===== ETAPA 4: plan (sin cambios) =====
python tools\cobertura_muestras.py --base --csv datasets_lsm\cobertura_antes.csv > datasets_lsm\etapa4_cobertura.txt 2>&1
type datasets_lsm\etapa4_cobertura.txt
python tools\aprobar_dataset.py --dataset alfabeto --por-glosa 10 --existentes sumar --seco > datasets_lsm\etapa4_alfabeto.txt 2>&1
type datasets_lsm\etapa4_alfabeto.txt
python tools\aprobar_dataset.py --dataset alfabeto_estatico --por-glosa 10 --existentes sumar --seco > datasets_lsm\etapa4_estatico.txt 2>&1
type datasets_lsm\etapa4_estatico.txt
python tools\aprobar_dataset.py --dataset iteso --por-glosa 10 --existentes sumar --seco > datasets_lsm\etapa4_iteso.txt 2>&1
type datasets_lsm\etapa4_iteso.txt
echo listo> datasets_lsm\etapa4.ok
echo.
echo ETAPA 4 TERMINADA (no se cambio nada)
pause
