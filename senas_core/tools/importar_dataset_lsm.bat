@echo off
rem Importa el dataset de LSM al diccionario (ver tools\importar_dataset_lsm.py).
rem   Primero:  importar_dataset_lsm.bat --probar 6
rem   Despues:  importar_dataset_lsm.bat
rem El resumen queda tambien en datasets_lsm\importacion.log
cd /d "%~dp0.."
python tools\importar_dataset_lsm.py %*
echo.
pause
