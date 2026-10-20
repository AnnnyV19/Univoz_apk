@echo off
rem Baja los videos de Wikisigns (ver tools\descargar_wikisigns.py). Reanuda si se corta.
rem   Prueba:  descargar_wikisigns.bat --prueba --probar 8
rem   Todo:    descargar_wikisigns.bat
cd /d "%~dp0.."
python tools\descargar_wikisigns.py %*
echo.
pause
