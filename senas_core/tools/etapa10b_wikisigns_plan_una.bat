@echo off
rem ETAPA 10b: SOLO PLAN en seco, igual que la etapa 10 pero con --compartidos una (un solo video por grupo de sinonimos
rem que comparten video: FALSA/FALSAMENTE/FALSO, etc.). NO aprueba, NO exporta, NO cambia la base ni plantillas.json.
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\etapa10b.ok 2>nul
set PYTHONIOENCODING=utf-8
echo ===== ETAPA 10b: planes en seco con --compartidos una =====
echo [1/2] Tanda a 600 en total, sin solo-mano, sin brazo colgando, un video por grupo
python tools\aprobar_dataset.py --dataset wikisigns --limite 600 --sin-solo-mano --reposo-maximo 0.5 --compartidos una --seco > datasets_lsm\etapa10b_plan_5_600_una.txt 2>&1
echo [2/2] Todo lo aprobable con esos filtros
python tools\aprobar_dataset.py --dataset wikisigns --todas --sin-solo-mano --reposo-maximo 0.5 --compartidos una --seco > datasets_lsm\etapa10b_plan_6_todas_una.txt 2>&1
echo listo> datasets_lsm\etapa10b.ok
echo.
echo ETAPA 10b TERMINADA (nada se aprobo ni se exporto). Resultados en datasets_lsm\etapa10b_plan_*.txt
timeout /t 8
