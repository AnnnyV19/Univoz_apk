@echo off
rem Sube a Supabase Storage los videos del dataset LSM ya importado (ver tools\subir_videos_dataset.py).
rem   Primero:  subir_videos_dataset.bat --seco
rem   Luego:    subir_videos_dataset.bat --probar 3
rem   Despues:  subir_videos_dataset.bat
cd /d "%~dp0.."
python tools\subir_videos_dataset.py %*
echo.
pause
