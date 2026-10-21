@echo off
rem EJEMPLAR DEL AVATAR: para cada sena elige la toma "del medio" del grupo (la que mas se parece a todas las demas)
rem y agrega una copia como PRIMERA plantilla, que es la que reproduce el avatar. No mueve ni normaliza alturas.
rem Por defecto solo las frases del camino de aprendizaje (15). Las letras no se tocan. Respaldo en D:\UNIVOZ_APK\_respaldo_antes_de_ejemplar
rem Se puede correr varias veces sin duplicar. NO descarga nada.
cd /d "%~dp0"
echo ===== EJEMPLAR DEL AVATAR =====
echo [1/2] prueba en seco (muestra la tabla, no cambia nada)
python ejemplar_avatar.py --solo-probar
if errorlevel 1 goto mal
echo [2/2] aplicando con respaldo
python ejemplar_avatar.py
if errorlevel 1 goto mal
echo.
echo LISTO. Corre la app completa (correr_univoz.bat o flutter run).
goto fin
:mal
echo.
echo SE DETUVO: lee el mensaje de arriba. No se cambio plantillas.json si no dice "Listo".
:fin
pause
