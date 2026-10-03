@echo off
chcp 65001 >nul
REM ============================================================
REM  Pruebas antes de hacer commit (Windows). Equivale a:
REM      ./scripts/univoz.sh test
REM  Para en el primer fallo y lo dice. Requiere Flutter, Python 3
REM  (con pytest) y Node.js en el PATH.
REM ============================================================
setlocal
where py >nul 2>&1 && (set "PY=py -3") || (set "PY=python")
cd /d "%~dp0.."
set "RAIZ=%CD%"

echo [1/8] Flutter tests senas_core
cd /d "%RAIZ%\senas_core" && call flutter test || goto :fallo
echo [2/8] Flutter analyze senas_core
call flutter analyze || goto :fallo
echo [3/8] Flutter tests univoz
cd /d "%RAIZ%\univoz" && call flutter test || goto :fallo
cd /d "%RAIZ%"
echo [4/8] Python (normalizacion, SignSpace, perfil, sesiones)
%PY% -m pytest -q senas_core || goto :fallo
%PY% senas_core\tools\test_norm.py || goto :fallo
%PY% senas_core\tools\test_dtw.py || goto :fallo
echo [5/8] AI Engine
set "PYTHONPATH=%RAIZ%\backend\ai-engine"
%PY% -m pytest -q backend\ai-engine\tests || goto :fallo
echo [6/8] Copias Kotlin de univoz sincronizadas
%PY% senas_core\tools\sincronizar_kotlin.py --check || (
  echo Corre: %PY% senas_core\tools\sincronizar_kotlin.py
  goto :fallo
)
echo [7/8] Visor sincronizado con los modulos .mjs
%PY% senas_core\tools\inline_viewer_modules.py --check || (
  echo Corre: %PY% senas_core\tools\inline_viewer_modules.py
  goto :fallo
)
echo [8/8] Pruebas JavaScript del rig
cd /d "%RAIZ%\senas_core\tools\rig-tests"
if not exist node_modules\three call npm install || goto :fallo
call npm test || goto :fallo

echo.
echo ===== TODO EN VERDE =====
endlocal
exit /b 0

:fallo
echo.
echo ===== FALLO: revisa el mensaje de arriba antes de hacer commit =====
endlocal
exit /b 1
