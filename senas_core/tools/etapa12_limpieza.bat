@echo off
rem ETAPA 12 (limpieza, 13-oct): NO aprueba nada y NO exporta plantillas.json.
rem [1] ve (en seco) que pasaria con las muestras de palabras "a revisar" que siguen aprobadas
rem [2] prueba como clasifica la lista algunas palabras dudosas
rem [3] rechaza lo de [bloquear] que aun este pendiente (hoy: 1 muestra de QUE_CABRON); deja .sql para revertir
rem [4] flutter analyze + flutter test (incluye el widget_test.dart nuevo)  -> D:\UNIVOZ_APK\salida_verificacion.txt
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\etapa12.ok 2>nul
set PYTHONIOENCODING=utf-8
echo ===== ETAPA 12: limpieza =====
echo [1/4] Palabras a revisar aprobadas (en seco)
python tools\moderar_senas.py --seco --retener-revisar > datasets_lsm\etapa12_revisar_seco.txt 2>&1
echo [2/4] Probar palabras dudosas
python tools\moderar_senas.py --probar _DL YUC "Que cabron" vagina "tu mismo" > datasets_lsm\etapa12_probar.txt 2>&1
echo [3/4] Rechazar lo bloqueado que siga pendiente
python tools\moderar_senas.py > datasets_lsm\etapa12_bloqueadas.txt 2>&1
echo listo> datasets_lsm\etapa12.ok
echo [4/4] flutter analyze y test (tarda unos minutos)
call D:\UNIVOZ_APK\verificar_flutter.bat
echo.
echo ETAPA 12 TERMINADA (nada se aprobo ni se exporto)
timeout /t 10
