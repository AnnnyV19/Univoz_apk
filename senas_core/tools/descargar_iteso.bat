@echo off
rem Baja los videos de ITESO-MX-100 (ver tools\descargar_iteso.py). Reanuda si se corta.
rem   Primero:  descargar_iteso.bat --seco
rem   Prueba:   descargar_iteso.bat --probar 6
rem   Todo:     descargar_iteso.bat
cd /d "%~dp0.."
python tools\descargar_iteso.py %*
echo.
pause
