# Publicar Univoz (Android)

Versión actual: 0.9.0+9 (`univoz/pubspec.yaml`, línea `version:`). El texto de
versión que ve la persona (`kVersionApp`) debe decir lo mismo: lo vigila
`univoz/test/configuracion_test.dart`.

## 1. Crear la llave de firma (una sola vez)

```bash
keytool -genkey -v -keystore ~/univoz-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias univoz
```

Guarda `univoz-release.jks` y sus contraseñas en un lugar seguro y con copia.
**Si la pierdes no podrás actualizar la app** (en Play, solo si no activaste
Play App Signing). Nunca la subas a git: `.gitignore` ya excluye `key.properties`,
`*.jks` y `*.keystore`.

## 2. `univoz/android/key.properties`

```properties
storePassword=<contraseña del almacén>
keyPassword=<contraseña de la llave>
keyAlias=univoz
storeFile=/home/tu-usuario/univoz-release.jks
```

`storeFile` es una ruta absoluta (o relativa a `univoz/android/app`). Sin este
archivo, `flutter build apk --release` falla a propósito con
"Falta android/key.properties: ver docs/RELEASE.md". Compilar en debug y
correr los tests no lo necesitan.
Si falta un campo (o `storeFile` no apunta a un archivo que existe), el build
release falla antes de compilar con un mensaje que nombra el campo:
"android/key.properties no tiene: keyAlias. Ver docs/RELEASE.md, sección 2.".

## 3. Compilar

```bash
cd univoz
flutter build apk --release --split-per-abi    # APK por arquitectura (instalación directa)
flutter build appbundle --release              # .aab para Google Play
```

Salida:

- `univoz/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` (casi todos los
  teléfonos desde 2017), `app-armeabi-v7a-release.apk` (teléfonos viejos de 32 bits)
  y `app-x86_64-release.apk` (emuladores).
- `univoz/build/app/outputs/bundle/release/app-release.aab`.

Antes de compilar sincroniza el visor y el Kotlin (si cambiaste algo en `senas_core`):

```bash
python3 senas_core/tools/inline_viewer_modules.py
python3 senas_core/tools/sincronizar_kotlin.py
./scripts/univoz.sh test
```

El release usa R8 (minificar y quitar recursos). Las reglas están en
`univoz/android/app/proguard-rules.pro` (MediaPipe, protobuf y los plugins propios).
Después de un cambio de dependencias prueba el APK release en un teléfono:
una regla que falte se nota en la cámara o en el avatar, no al compilar.

**Nunca pases `UNIVOZ_BACKEND_URL` (ni `--dart-define=UNIVOZ_BACKEND_URL=...`)
en un build público.** Es solo para pruebas con un servidor local (apunta a una IP de tu red) y, si se
queda en el build, la app pública intentaría hablar con ese servidor. Compila
el release con el comando de arriba tal cual, sin `--dart-define`.

Después de compilar el `.aab`, sube a Play Console el archivo de mapeo de R8
(`univoz/build/app/outputs/mapping/release/mapping.txt`), en la versión, sección
"Archivos de desofuscación". Sin él, los fallos que reporte Play salen
ilegibles. Guarda una copia del `mapping.txt` de cada versión publicada.

### Prueba de humo del release (en el teléfono, antes de repartirlo)

Instala el APK release (no el debug) y comprueba, con el teléfono real:

- [ ] La app abre sin cerrarse; "Acerca de" dice la versión esperada.
- [ ] Reconocer: la cámara arranca y el esqueleto sigue tus manos (MediaPipe
      sobrevivió a R8). Voltea la cámara y comprueba que el avatar sigue
      moviéndose y que Automático detecta una seña.
- [ ] El avatar 3D carga, también con wifi y datos apagados.
- [ ] Voz: "Leer en voz alta" habla y el botón vuelve a "Leer en voz alta" al
      terminar; dictado (micrófono) escribe lo que dices.
- [ ] SOS: el botón abre el marcador con el contacto, el SMS lleva el texto
      correcto (también desde un teléfono prestado) y el 911 pide confirmar.
- [ ] Compartir el registro de errores funciona (Configuración).
- [ ] `adb logcat | grep -i chromium` no muestra `Uncaught` al abrir el avatar.
- [ ] Prueba también con TalkBack encendido y en un teléfono de gama baja.

## 4. Instalar para testers

Con el teléfono por USB y depuración USB activada:

```bash
adb install -r univoz/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

O manda el `.apk` por mensaje/Drive y que lo abran (deben permitir "instalar
apps desconocidas" para ese origen).

**Instalar un release encima de un debug (o al revés) falla** con
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`: están firmados con llaves distintas.
Hay que desinstalar la app antes (`adb uninstall com.univoz.app`) y eso **borra
todos sus datos** (perfil, contacto de emergencia, muestras, sesiones y
consentimiento). Avisa a quien lo tenga instalado antes de pedírselo.

Importante: el `applicationId` cambió de `com.example.univoz` a `com.univoz.app`.
La app nueva **se instala junto a la vieja**, no la reemplaza, y **no migra los
datos** (perfil, contacto de emergencia, muestras y consentimiento empiezan de
cero). Pide a los testers que desinstalen la versión `com.example.univoz`. A
partir de ahora el `applicationId` no debe volver a cambiar: es la identidad de
la app en Play.

## 5. Checklist de Google Play

- [ ] Cuenta de Play Console (pago único de 25 USD) y verificación de identidad.
- [ ] Crear la app en Play Console: nombre "Univoz", idioma español (México),
      app gratuita, categoría Comunicación o Herramientas.
- [ ] Activar **Play App Signing**; subir el `.aab` firmado con tu llave
      (será la llave de subida).
- [ ] **Política de privacidad**: publicar el contenido de `docs/PRIVACIDAD.md`
      en una URL pública y ponerla en la ficha.
- [ ] **Seguridad de los datos** (Data safety), derivado de `docs/PRIVACIDAD.md`:
  - Fotos y video: la cámara se procesa en el dispositivo y no se recopila ni
    comparte. Responde que no se recopilan.
  - Audio: el micrófono se usa para dictado; Univoz no guarda ni envía audio
    (el reconocimiento lo hace el servicio de voz del sistema). No se recopila.
  - Datos de actividad en la app / otros datos: las muestras de señas
    (puntos de manos y cuerpo, sin imagen) **sí se recopilan solo si la persona
    elige subirlas** (Sincronizar): recopilados, opcionales, uso "mejorar la
    app", no compartidos con terceros (el servidor es Supabase, tratado como
    encargado de tratamiento propio).
  - Contactos / información personal: el contacto de emergencia se guarda solo
    en el teléfono: no se recopila.
  - Identificadores y anuncios: ninguno. Sin analítica.
  - Cifrado en tránsito: sí (HTTPS). Mecanismo para pedir el borrado de datos:
    indicar el correo de contacto (ver el último punto de PRIVACIDAD).
- [ ] **Clasificación de contenido**: cuestionario IARC (sin violencia, sin
      compras, sin contenido generado por usuarios visible a otros).
- [ ] **Declaración de permisos sensibles**: cámara (reconocer señas) y
      micrófono (dictado). `INTERNET` no requiere declaración.
- [ ] **Declaración de accesibilidad / audiencia**: público general; no
      dirigida a menores de 13 años.
- [ ] **Capturas de pantalla** (mín. 2 de teléfono), ícono 512x512 y gráfico de
      funciones 1024x500; texto breve y descripción completa en español.
- [ ] **Pistas de prueba**: Prueba interna (hasta 100 testers, sin revisión) ->
      Prueba cerrada (cuentas nuevas personales: al menos 12 testers durante
      14 días seguidos antes de pedir producción) -> Prueba abierta -> Producción.
- [ ] **Nivel de API objetivo**: Play exige que las apps nuevas apunten al API
      más reciente que pida la política vigente (hoy `targetSdk` sale de
      `flutter.targetSdkVersion`). Revisa la fecha límite en Play Console antes
      de cada envío y actualiza Flutter si hace falta.
- [ ] Tamaño: el `.aab` genera APK por arquitectura y por densidad, así que a
      los usuarios les llega mucho menos que el APK universal.
