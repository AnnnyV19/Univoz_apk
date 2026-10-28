@echo off
chcp 65001 >nul
rem ============================================================
rem  Panel del recolector nocturno: abre http://127.0.0.1:8731
rem  Muestra en vivo que hace, te deja revisar las muestras (video +
rem  esqueleto), suavizar, recortar, y ensena lo que va aprendiendo.
rem  Cierra esta ventana para apagar el panel.
rem ============================================================
cd /d "%~dp0.."
set "PY=python"
where py >/dev/null 2>&1 && set "PY=py -3"
set PYTHONIOENCODING=utf-8
%PY% tools\panel_recolector.py
pause
