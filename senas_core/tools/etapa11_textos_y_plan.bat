@echo off
rem ETAPA 11: (1) corrige acentos/textos cortados de senas de Wikisigns en la base (solo signs.espanol; guarda un .sql para deshacer),
rem (2) vuelve a calcular en SECO los planes con --compartidos una. NO aprueba nada, NO exporta, NO toca plantillas.json.
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\etapa11.ok datasets_lsm\etapa11.fallo 2>nul
set PYTHONIOENCODING=utf-8
echo ===== ETAPA 11: textos de Wikisigns + planes en seco =====
echo [1/4] Textos: lo que se cambiaria (sin escribir)
python tools\corregir_textos_wikisigns.py > datasets_lsm\etapa11_textos_ver.txt 2>&1
if errorlevel 1 (echo paro> datasets_lsm\etapa11.fallo & echo FALLO el paso 1; no se cambio nada. Mira datasets_lsm\etapa11_textos_ver.txt & timeout /t 20 & exit /b 1)
echo [2/4] Textos: aplicar (solo si el texto actual es exactamente el esperado)
python tools\corregir_textos_wikisigns.py --aplicar > datasets_lsm\etapa11_textos_aplicar.txt 2>&1
if errorlevel 1 (echo paro> datasets_lsm\etapa11.fallo & echo FALLO el paso 2; la transaccion se revirtio. Mira datasets_lsm\etapa11_textos_aplicar.txt & timeout /t 20 & exit /b 1)
echo [3/4] Plan en seco: tanda a 600 en total, un video por grupo de sinonimos
python tools\aprobar_dataset.py --dataset wikisigns --limite 600 --sin-solo-mano --reposo-maximo 0.5 --compartidos una --seco > datasets_lsm\etapa10b_plan_5_600_una.txt 2>&1
echo [4/4] Plan en seco: todo lo aprobable, un video por grupo
python tools\aprobar_dataset.py --dataset wikisigns --todas --sin-solo-mano --reposo-maximo 0.5 --compartidos una --seco > datasets_lsm\etapa10b_plan_6_todas_una.txt 2>&1
echo listo> datasets_lsm\etapa11.ok
echo.
echo ETAPA 11 TERMINADA (nada se aprobo ni se exporto). Resultados: datasets_lsm\etapa11_*.txt y etapa10b_plan_*.txt
timeout /t 10
