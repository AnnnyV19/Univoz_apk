@echo off
rem ETAPA 2a: letras ESTATICAS de CICESE (Zenodo 10067509, MSL-ABC.7z 4.8 GB, necesita ~11 GB libres).
rem Baja, descomprime, dice como entendio las carpetas (--listar) y prueba 6 tomas SIN tocar la base.
cd /d "%~dp0.."
if not exist datasets_lsm mkdir datasets_lsm
del /q datasets_lsm\etapa2a.ok datasets_lsm\etapa2a.fallo 2>nul
set PYTHONIOENCODING=utf-8
echo ===== ETAPA 2a: letras estaticas (ver y probar) =====
echo (baja 4.8 GB y descomprime; la pantalla se llena al terminar cada paso. Avance en datasets_lsm\importacion.log)
python tools\importar_alfabeto_estatico.py --listar > datasets_lsm\etapa2a_listar.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa2a_listar.txt
if not "%ERR%"=="0" goto mal
python tools\importar_alfabeto_estatico.py --probar 6 > datasets_lsm\etapa2a_probar.txt 2>&1
set ERR=%errorlevel%
type datasets_lsm\etapa2a_probar.txt
if not "%ERR%"=="0" goto mal
echo listo> datasets_lsm\etapa2a.ok
echo.
echo ETAPA 2a TERMINADA
goto fin
:mal
echo paro> datasets_lsm\etapa2a.fallo
echo.
echo ETAPA 2a SE DETUVO: lee el mensaje de arriba
:fin
pause
