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
flutter build web --release
python -m http.server 8731 --bind 0.0.0.0 --directory build\web
```

Con teléfono y PC en misma red Wi-Fi, consultar IPv4 con `ipconfig` y abrir:

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
