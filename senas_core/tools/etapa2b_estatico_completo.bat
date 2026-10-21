@echo off
rem ETAPA 2b: letras ESTATICAS, todas las tomas del grupo A (20 personas por letra) -> base como 'pendiente'.
cd /d "%~dp0.."
del /q datasets_lsm\etapa2b.ok datasets_lsm\etapa2b.fallo 2>nul
set PYTHONIOENCODING=utf-8
echo ===== ETAPA 2b: letras estaticas (completo) =====
python tools\importar_alfabeto_estatico.py
if errorlevel 1 goto mal
echo listo> datasets_lsm\etapa2b.ok
echo.
echo ETAPA 2b TERMINADA
goto fin
:mal
echo paro> datasets_lsm\etapa2b.fallo
echo.
echo ETAPA 2b SE DETUVO: lee el mensaje de arriba y datasets_lsm\importacion.log
:fin
pause
