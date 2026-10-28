@echo off
chcp 65001 >nul
rem ============================================================
rem  Registra la tarea programada de Windows "UNIVOZ recolector" que corre
rem  recolector_nocturno.bat todos los días a las 3:17 a. m. (con la PC
rem  encendida). Para quitarla:  schtasks /delete /tn "UNIVOZ recolector" /f
rem ============================================================
schtasks /create /tn "UNIVOZ recolector" /sc daily /st 03:17 /tr "\"%~dp0recolector_nocturno.bat\"" /f
echo.
echo Listo. Para probarla ya:  schtasks /run /tn "UNIVOZ recolector"
pause
