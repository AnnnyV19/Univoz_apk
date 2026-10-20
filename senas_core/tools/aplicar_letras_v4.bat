@echo off
rem LETRAS v4 del alfabeto LSM: K L LL M N(tilde) O P Q R RR S Z corregidas con formas de mano limpias y movimiento.
rem Inserta cada letra como PRIMERA plantilla de su glosa en D:\UNIVOZ_APK\univoz\assets\plantillas.json (el avatar toma la primera).
rem Las plantillas reales no se borran. Se hace respaldo en D:\UNIVOZ_APK\_respaldo_antes_de_letras_v4 antes de escribir.
rem Se puede correr varias veces sin duplicar. NO descarga nada.
cd /d "%~dp0"
echo ===== LETRAS v4 =====
echo [1/2] prueba en seco (no cambia nada)
python aplicar_letras_v4.py --solo-probar
if errorlevel 1 goto mal
echo [2/2] aplicando con respaldo
python aplicar_letras_v4.py
if errorlevel 1 goto mal
echo.
echo LISTO. Ahora corre la app completa (correr_univoz.bat o flutter run); hot reload no recarga los assets.
goto fin
:mal
echo.
echo SE DETUVO: lee el mensaje de arriba. No se cambio plantillas.json si no dice "Listo".
:fin
pause
