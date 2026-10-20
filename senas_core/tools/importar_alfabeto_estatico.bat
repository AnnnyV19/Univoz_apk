@echo off
rem Importa el alfabeto ESTATICO de la LSM (solo forma de mano; ver tools\importar_alfabeto_estatico.py).
rem Primero:  importar_alfabeto_estatico.bat --listar   (si ya tienes las imagenes: --carpeta RUTA)
rem Despues:  importar_alfabeto_estatico.bat --probar 6
rem Luego:    importar_alfabeto_estatico.bat
cd /d "%~dp0.."
python tools\importar_alfabeto_estatico.py %*
pause
