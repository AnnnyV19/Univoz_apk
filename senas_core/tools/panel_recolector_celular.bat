@echo off
chcp 65001 >nul
rem ============================================================
rem  Igual que panel_recolector.bat, pero tambien se abre desde tu
rem  celular conectado al mismo Wi-Fi (con clave). En el panel de la
rem  PC sale el boton "Abrir en el celular" con un codigo QR.
rem  La primera vez Windows puede preguntar por el Firewall: permite
rem  solo "Redes privadas". Cierra esta ventana para apagarlo.
rem ============================================================
cd /d "%~dp0.."
set "PY=python"
where py >nul 2>&1 && set "PY=py -3"
set PYTHONIOENCODING=utf-8
%PY% tools\panel_recolector.py --red
pause
