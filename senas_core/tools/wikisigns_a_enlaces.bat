@echo off
rem Arma videos\enlaces_wikisigns.txt con las senas de LSM de Wikisigns (ver tools\wikisigns_a_enlaces.py).
rem   Primero:  wikisigns_a_enlaces.bat --seco
rem   Prueba:   wikisigns_a_enlaces.bat --probar 8
rem   Todo:     wikisigns_a_enlaces.bat      (~7 h, reanuda si lo cortas)
cd /d "%~dp0.."
python tools\wikisigns_a_enlaces.py %*
echo.
pause
