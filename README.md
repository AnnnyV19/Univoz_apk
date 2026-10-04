# Univoz

Reconocimiento de lengua de señas con cámara y un avatar 3D (VRM) que
copia los movimientos del usuario o reproduce señas grabadas. La captura usa
**MediaPipe Holistic** (cuerpo, manos y cara en una sola pasada) en el
navegador y en Android.

## Qué hay en el repo

| Carpeta | Qué es |
|---|---|
| `senas_core/` | Núcleo: normalización, reconocimiento (DTW), visor del avatar, captura Android (Kotlin) y la **app de laboratorio** (`com.univoz.senas_app`) |
| `univoz/` | **App producto** (`com.example.univoz`). Usa `senas_core` como librería |
| `backend/ai-engine/` | Clasificador opcional (FastAPI) |
| `docs/` | Documentación de ingeniería: arquitectura, contratos, plan por fases |
| `scripts/` | `web.bat` / `test.bat` (Windows) y `univoz.sh` (Linux/macOS) |

El visor del avatar vive en `senas_core/assets/avatar_viewer/` y hay una
copia idéntica en `univoz/assets/avatar_viewer/` (se sincroniza por script,
ver más abajo).

## Requisitos (Windows)

1. **Git**: https://git-scm.com/download/win
2. **Flutter** (canal stable): https://docs.flutter.dev/get-started/install/windows
   y que `flutter doctor` no marque errores en Flutter.
3. **Python 3.11+**: https://www.python.org/downloads/ — durante la
   instalación marca **"Add python.exe to PATH"**. Luego, en una terminal:
   ```bat
   py -3 -m pip install pytest
   ```
4. **Node.js 20 o más nuevo** (LTS): https://nodejs.org/ — solo para las
   pruebas del avatar.
5. **Android Studio** (para compilar el APK): https://developer.android.com/studio
   — instala el SDK desde su asistente y luego `flutter doctor --android-licenses`.
6. **Chrome o Edge** para la versión web.

## Primeros pasos

```bat
git clone https://github.com/AnnnyV19/Univoz_apk.git
cd Univoz_apk
git checkout karim
cd senas_core && flutter pub get && cd ..
cd univoz && flutter pub get && cd ..
```

## Probar en el navegador (lo más rápido)

Doble clic en **`scripts\web.bat`** (o desde una terminal en la carpeta del
repo: `scripts\web.bat`). Abre el navegador en:

```
http://127.0.0.1:8080/assets/avatar_viewer/index.html?standalone=1
```

1. Pulsa **Iniciar cámara** y acepta el permiso del navegador.
2. La primera vez aparece un aviso de **consentimiento**: si aceptas, cada
   vez que enciendas la cámara se mide tu cuerpo y se **graba la sesión**
   (solo puntos del cuerpo, manos y cara; **nunca video ni imágenes**).
3. Al empezar, colócate a una distancia en la que **se vean tus brazos**
   hasta que diga "Perfil corporal listo".

La ventana negra de `web.bat` es el servidor: ciérrala para apagarlo.

### Opciones del panel y de la URL

| Opción | Para qué |
|---|---|
| Casilla *Adaptar a mi cuerpo (anclas)* | Mueve los brazos del avatar con las proporciones del avatar (tocar el mentón = tocar SU mentón). Experimental |
| Casilla *Vista espejo (para mí)* | El avatar se mueve como tu reflejo. Para traducir a otra persona déjala apagada |
| `&res=640` | Cámara a 640×480 en vez de 360×270 (para comparar calidad de manos) |
| `&captura=separado` | Pose lite + Hand + Face en vez de Holistic (más lento con video real; solo para comparar) |
| `&worker=0` | MediaPipe en el hilo principal (comparación; el avatar se traba) |
| `&stream=0` | El worker recibe frames enviados por la página en vez de leer la cámara directo |
| Botones *Sesión JSONL* / *Borrar mis datos* | Descargar la sesión actual / borrar perfil y consentimiento |

### Grabar una sesión de prueba útil

Durante la sesión pulsa las teclas **1 a 9** al empezar cada paso; quedan
marcadas para el análisis:

| Tecla | Gesto (unos 5 s cada uno) |
|---|---|
| 1 | Quieto, brazos abajo |
| 2 | Solo mano derecha arriba, luego solo la izquierda |
| 3 | Ambos brazos estirados hacia la cámara |
| 4 | Manos frente al pecho, cruzándose y tocándose |
| 5 | Mano frente a la cara, tocar nariz y mentón |
| 6 | Girar la cabeza a los lados y arriba/abajo |
| 7 | Abrir la boca, sonreír, levantar cejas, parpadear |
| 8 | Señas reales, rápidas |
| 9 | Salir parcialmente del cuadro y volver |

Termina con **Detener**. La sesión queda en `senas_core\sesiones\<id>.jsonl`.

**Sesión de manos** (gates de orientación e identidad): abre el visor con
`&protocolo=manos`; las mismas teclas significan:

| Tecla | Maniobra (unos 5 s cada una) |
|---|---|
| 1 | Estática, manos abiertas |
| 2 | Pulgar: abierto → palma → tocar índice |
| 3 | Girar palma ↔ dorso |
| 4 | Cerrar el puño lento |
| 5 | Pronación (girar antebrazo) |
| 6 | Cruzar y tocar manos |
| 7 | Tapar una mano ~200 ms |
| 8 | Tapar una mano ~500 ms |
| 9 | Sacar la mano del cuadro y volver |

### Analizar sesiones

```bat
py -3 senas_core\tools\analizar_sesion.py
py -3 senas_core\tools\analizar_sesion.py --comparar senas_core\sesiones\A.jsonl senas_core\sesiones\B.jsonl
py -3 senas_core\tools\analizar_sesion.py --baseline
py -3 senas_core\tools\analizar_sesion.py --gates
```

Muestra cobertura (pose, manos, cara), manos rechazadas por el filtro
anti-alucinación, errores más comunes, tiempos, profundidad, auditoría
contra el perfil corporal y resultados por paso (teclas 1–9). `--gates` da
PASS / PROVISIONAL / FAIL / SIN_DATOS por fase según `docs/10` y lo guarda en
`docs/evidence/gates/`.

## App Android

Conecta el teléfono con **depuración USB** activada y, desde la carpeta del
repo:

```bat
cd univoz
flutter build apk --debug
flutter install --debug
```

> Usa siempre `--debug` en `flutter install`: sin él busca el APK de
> release, no lo encuentra y **desinstala** la versión que había.
> `correr_univoz.bat` hace todo esto y guarda la salida en un archivo
> (revisa la ruta `D:\UNIVOZ_APK` de su interior antes de usarlo).

En la app, las pantallas con cámara piden el mismo consentimiento y graban
la sesión en el teléfono. Para pasarla a la PC: **Ajustes → Compartir última
sesión**. **Ajustes → Borrar mis datos** elimina consentimiento, perfil y
sesiones.

## Antes de hacer commit

```bat
scripts\test.bat
```

Corre las pruebas de Flutter, Python, backend, JavaScript y verifica que las
copias sincronizadas estén al día. Si dice **FALLO**, no hagas commit.

Pruebas de Kotlin (motor de cámara Android):

```bat
cd senas_core\android
gradlew.bat :app:testDebugUnitTest
```

## Reglas para no romper nada

- **Visor del avatar**: edita los módulos `senas_core\assets\avatar_viewer\rig_*.mjs`
  y luego regenera `index.html` y la copia de `univoz`:
  ```bat
  py -3 senas_core\tools\inline_viewer_modules.py
  ```
  (Android carga el visor como archivo local y no puede importar módulos
  separados; por eso viven también dentro de `index.html`.)
- **Kotlin de cámara**: edita solo `senas_core\android\...\com\univoz\senas\*.kt`
  y copia a `univoz` con:
  ```bat
  py -3 senas_core\tools\sincronizar_kotlin.py
  ```
- **El vector de 152 valores** (`MotionFrameV2`, `norm_version 2.0.0`) no se
  cambia: de él dependen las muestras y el clasificador.
- **Privacidad**: nunca se guarda video; el perfil corporal y las sesiones
  son locales y borrables, y solo con consentimiento. La carpeta
  `senas_core\sesiones\` no se sube a git.
- Los finales de línea están fijados en `.gitattributes`: no cambies la
  configuración `core.autocrlf` para estos archivos.

## Linux / macOS

Lo mismo con `./scripts/univoz.sh web` y `./scripts/univoz.sh test`, y
`python3` en lugar de `py -3`.

## Más documentación

- [`docs/README.md`](docs/README.md): índice de la documentación.
- [`docs/12-plan-sistema-unico.md`](docs/12-plan-sistema-unico.md): plan por
  fases y qué está hecho.
- [`docs/13-mapeo-corporal-universal.md`](docs/13-mapeo-corporal-universal.md):
  cómo se adapta cualquier cuerpo al avatar.
- [`docs/02-contratos-y-datos.md`](docs/02-contratos-y-datos.md): formatos de
  datos (vector 152D, SignSpaceFrame, perfil corporal, sesiones).
