@echo off
chcp 65001 >nul
REM ============================================================
REM  Compila e instala la app UNIVOZ de verdad (com.example.univoz),
REM  la que tiene el flujo de perfiles.
REM
REM  El problema que esto resuelve: correr "flutter run" desde
REM  D:\UNIVOZ_APK\senas_core compila com.univoz.senas_app, que para
REM  Android es OTRA app. Por eso la app del flujo de perfiles nunca
REM  se actualizaba en el celular aunque se compilara una y otra vez.
REM
REM  Todo lo que imprime queda guardado en salida_univoz.txt.
REM ============================================================

set LOG=D:\UNIVOZ_APK\salida_univoz.txt

echo ========== UNIVOZ: compilar e instalar ==========> "%LOG%"
echo Fecha: %DATE% %TIME%>> "%LOG%"
echo.>> "%LOG%"

cd /d D:\UNIVOZ_APK\univoz
echo Carpeta desde la que se compila: %CD%>> "%LOG%"
echo (tiene que decir D:\UNIVOZ_APK\univoz, NO senas_core)>> "%LOG%"
echo.>> "%LOG%"

echo ---------- flutter devices ---------->> "%LOG%"
call flutter devices>> "%LOG%" 2>&1
echo.>> "%LOG%"

echo ---------- flutter pub get ---------->> "%LOG%"
call flutter pub get>> "%LOG%" 2>&1
echo.>> "%LOG%"

echo ---------- flutter build apk --debug ---------->> "%LOG%"
call flutter build apk --debug>> "%LOG%" 2>&1
echo.>> "%LOG%"

echo ---------- flutter install --debug ---------->> "%LOG%"
REM --debug es obligatorio: sin el, "flutter install" busca
REM app-release.apk (instala en release por omision), no lo encuentra
REM porque compilamos en debug, y ademas DESINSTALA la version que ya
REM estaba en el telefono antes de fallar -- dejandolo sin app.
call flutter install --debug>> "%LOG%" 2>&1
echo.>> "%LOG%"

echo ========== FIN ==========>> "%LOG%"

type "%LOG%"
echo.
echo ------------------------------------------------------------
echo Todo esto quedo guardado en: %LOG%
echo ------------------------------------------------------------
pause
