@echo off
rem ETAPA 10: SOLO PLAN en seco para aprobar mas de Wikisigns. NO aprueba, NO exporta, NO cambia la base ni plantillas.json.
rem Cada corrida usa --seco: calcula y escribe el reporte en datasets_lsm\etapa10_plan_*.txt y un CSV aprobacion_*_seco.csv.
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\etapa10.ok 2>nul
set PYTHONIOENCODING=utf-8
echo ===== ETAPA 10: planes en seco de Wikisigns =====
echo [1/4] Tabla de tandas
python tools\aprobar_dataset.py --dataset wikisigns --seco > datasets_lsm\etapa10_plan_1_tabla.txt 2>&1
echo [2/4] Tanda a 600 en total, sin filtros de altura
python tools\aprobar_dataset.py --dataset wikisigns --limite 600 --seco > datasets_lsm\etapa10_plan_2_600.txt 2>&1
echo [3/4] Tanda a 600 en total, sin solo-mano y sin brazo colgando (max 50%%)
python tools\aprobar_dataset.py --dataset wikisigns --limite 600 --sin-solo-mano --reposo-maximo 0.5 --seco > datasets_lsm\etapa10_plan_3_600_filtrado.txt 2>&1
echo [4/4] Tanda a 1000 en total, mismos filtros
python tools\aprobar_dataset.py --dataset wikisigns --limite 1000 --sin-solo-mano --reposo-maximo 0.5 --seco > datasets_lsm\etapa10_plan_4_1000_filtrado.txt 2>&1
echo listo> datasets_lsm\etapa10.ok
echo.
echo ETAPA 10 TERMINADA (nada se aprobo ni se exporto). Resultados en datasets_lsm\etapa10_plan_*.txt
timeout /t 8
