# Prueba rápida del avatar

## Antes de probar

Trabajar desde `KARIM`. Para subir muestras con enlace, abrir otra consola:

```bat
cd /d D:\univoz\senas\_core
python tools\servidor\_ingesta.py
```

Servidor de ingesta: `http://127.0.0.1:8730/`.

## Probar sin instalar Android

```bat
cd /d D:\univoz\Univoz_apk\univoz
```

`http://IP_DE_LA_PC:8731/` sirve para revisar interfaz, pero no habilita cámara en
teléfono. `getUserMedia` exige contexto seguro: usar HTTPS para la prueba real.

En PowerShell, desde esa carpeta:

```powershell
.\tool\probar_web_https.ps1
```

El script compila, crea certificado local, inicia Flutter Web HTTPS y muestra QR.
Con teléfono y PC en misma red Wi-Fi, abrir el QR. El navegador puede pedir aceptar
el certificado local una vez; después conceder permiso de cámara.

Si se necesita servidor estático HTTP solo para revisar avatar sin cámara:

```bat
python -m http.server 8731 --bind 0.0.0.0 --directory build\web
```

QR de prueba estática:

```text
http://IP_DE_LA_PC:8731/
```

QR opcional desde Node.js:

```bat
npx --yes -p qrcode-terminal node -e "require('qrcode-terminal').generate('http://IP_DE_LA_PC:8731/', {small:true})"
```

Visor web incluye `univozM.vrm` y modelos MediaPipe. Cámara pedirá permiso del
navegador. Para validar espejo, levantar brazo derecho: avatar debe levantar su
derecho anatómico; si no hay pose confiable, visor conserva lado anterior y no
adivina.

## Android

```bat
cd /d D:\univoz\Univoz_apk\univoz
flutter build apk --debug
```

APK: `build\app\outputs\flutter-apk\app-debug.apk`.

## Pruebas automáticas

```bat
cd /d D:\univoz\Univoz_apk\senas_core
flutter test
cd tools\rig-tests
npm ci
node --test motion.test.mjs
```
