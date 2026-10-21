# Guía del código

Cómo está organizado UNIVOZ y cómo trabajar en él. Para el análisis de
arquitectura y el informe de la revisión del 29/09/2026, ver el reporte
técnico aparte.

---

## Dónde está cada cosa

### `lib/` — la app (Flutter/Dart)

| Archivo | Qué hace |
| --- | --- |
| `sign_norm.dart` | **Normalización.** Convierte landmarks crudos en el vector de 32×152. Espejo exacto de `tools/sign_norm.py`. |
| `motion_contract.dart` | El contrato `MotionSequenceV2`: valida dimensiones, `norm_version`, fps y que no haya NaN. |
| `dtw.dart` | El clasificador. Prefiltro por firma, DTW con banda, y el margen que decide si se acepta. |
| `muestras_locales.dart` | Persistencia en el teléfono + `aGlosa()`. |
| `plantillas.dart` | Carga el diccionario: el paquete del APK + lo sincronizado + las muestras locales. |
| `supabase_api.dart` | Subir muestras y bajar el diccionario. |
| `camera_bridge.dart` | Recibe del nativo los landmarks por frame. |
| `avatar_bridge.dart` | Manda secuencias al visor VRM en el WebView. |
| `skeleton_painter.dart` | Dibuja el esqueleto y las manos sobre la cámara. |

### `android/.../kotlin/com/univoz/senas/` — el puente nativo

`LandmarkEngine.kt` corre MediaPipe; `HandTrackCoordinator.kt` decide qué
mano es cuál, y `LandmarkPlugin.kt` es el canal hacia Dart.

**Solo corre en ARM64.** El emulador x86 no sirve: las bibliotecas nativas
de MediaPipe no existen para esa arquitectura. Hay que probar en el teléfono.

### `tools/` — la ingesta (Python, corre en la PC)

| Archivo | Qué hace |
| --- | --- |
| `sign_norm.py` | La normalización. **Debe seguir idéntica a `sign_norm.dart`.** |
| `extraer_landmarks.py` | Corre MediaPipe sobre un video y asigna izquierda/derecha. |
| `ingest_video.py` | `ingest_un_video()`: el camino compartido por las tres vías de subida. |
| `ingest_carpeta.py` | Una carpeta entera, una seña por archivo. |
| `ingest_video_segmentos.py` | Un video con muchas señas, por tramos de un CSV. |
| `segmentar_video.py` | Detecta los tramos solo y escribe ese CSV. |
| `reconocer_video.py` | Prueba el reconocimiento contra la base, sin tocar el teléfono. |
| `exportar_paquete.py` | Genera `assets/plantillas.json`, el diccionario que viaja en el APK. |
| `probar_conexion.py` | Comprueba el `.env`, el esquema y el bucket. Correr antes de subir. |
| `configurar_env.py` | Arma el `.env` preguntando lo que falta. |

---

## Las tres reglas que no se pueden romper

**1. `sign_norm.py` y `sign_norm.dart` tienen que producir el mismo vector.**
Es lo que permite que una seña grabada en la PC y otra capturada en el
teléfono se puedan comparar. Lo verifica el golden test: `gen_golden.py`
escribe los casos desde Python y `test/sign_norm_test.dart` los comprueba
desde Dart. Si tocas una, toca la otra y regenera el golden.

**2. `a_glosa()` y `aGlosa()` tienen que dar la misma glosa.**
La glosa es el identificador de una seña. Si las dos implementaciones
difieren, la misma palabra escrita en la app y en un CSV crea dos filas
distintas en `signs`. Ojo con la `ñ`: va a `NN`, no a `N`, para que la letra
Ñ no choque con la N ni *año* con *ano*.

**3. Un cambio de `NORM_VERSION` invalida todos los datos anteriores.**
No son "parecidos": cambia el tamaño y el significado del vector. Hay que
insertar la fila nueva en `norm_versions`, reingerir los videos y regenerar
el paquete. La app ya descarta sola lo que no coincide.

---

## El flujo completo, de un video a la app

```bash
# 0. Comprobar que el entorno esté bien (no sube nada)
python tools/probar_conexion.py

# 1a. Una seña por archivo, toda una carpeta
python tools/ingest_carpeta.py --carpeta videos/ --signer TuNombre --mano derecha

# 1b. Muchas señas dentro de un mismo video
python tools/segmentar_video.py --video "videos/x.mp4" --mascara-sep      # detecta tramos
#     -> revisar el .segmentos.png, llenar la columna 'espanol' del CSV
python tools/segmentar_video.py --video x --rellenar-glosas "videos/x.segmentos.csv"
python tools/ingest_video_segmentos.py --video "videos/x.mp4" \
    --segmentos "videos/x.segmentos.csv" --mascara 0.66,0.06,1.00,0.90 --signer SEP

# 2. Aprobar en el SQL Editor de Supabase (las muestras entran como 'pendiente')

# 3. Meter el diccionario al APK
python tools/exportar_paquete.py

# 4. O bajarlo desde la app: Sincronizar -> Bajar el diccionario
```

Antes de cualquiera de los dos caminos de ingesta, `--seco` muestra el plan
sin tocar la base ni cargar MediaPipe.

---

## Cosas que ya nos mordieron

**La conexión a Supabase.** Usar el **Session pooler** (puerto 5432), no la
*Direct connection*: ese host solo resuelve con el add-on de IPv4, que es de
pago, y falla con `could not translate host name`, que suena a problema de
red. Y la contraseña va sin los corchetes del ejemplo.

**Un proyecto borrado y uno pausado dan errores distintos.** Un proyecto
pausado conserva su DNS; uno borrado no. Si `TU_REFERENCIA.supabase.co` no
resuelve, el proyecto no existe.

**Las claves nuevas `sb_secret_` necesitan la cabecera `apikey`.** Sin ella
el servidor lee el token como un JWT antiguo y responde `Invalid Compact
JWS`, que parece una clave equivocada.

**`cv2.imwrite()` no escribe en rutas con `ñ` o acentos en Windows.** Deja el
nombre con caracteres rotos. Hay que codificar con `cv2.imencode()` y
escribir con `open()`.

**Los videos de diccionario con recuadro superpuesto necesitan `--mascara`.**
Con `num_hands=2`, MediaPipe detecta también la mano de ese recuadro. Se
**tapa**, no se recorta: recortar cambia la relación de aspecto y deforma la
forma de la mano, que se guarda en coordenadas de imagen.

**Un `Text` suelto dentro de un `Row` desborda.** Hay que envolverlo en
`Expanded`. Ya pasó tres veces.

---

## Cómo depurar

Lo que funciona en este proyecto, por experiencia repetida: **capturar el
dato y mirarlo, en vez de deducir desde los primeros principios.** Los
cambios razonados a partir de la lógica (signos de ejes, espacios de
coordenadas, límites de ángulo) fallaron una y otra vez; los que salieron de
mirar un JSON de pose capturado acertaron rápido.

Las herramientas para eso:

- `tools/editor_pose.html` — captura poses con la webcam y saca pares
  `.json` / `.png`.
- `tools/hoja_contactos.py` — un video entero en una sola imagen, con los
  tiempos escritos encima. Para mirar antes de procesar.
- `tools/segmentar_video.py --solo-roi` — dibuja las zonas sobre un
  fotograma para verificarlas antes de correr nada.
- `tools/reconocer_video.py` — prueba el reconocimiento sin el teléfono.

Los tests corren sin MediaPipe ni base de datos:

```bash
python tools/test_norm.py    # normalización + el golden contra Dart
python tools/test_dtw.py     # clasificador
python tools/test_manos.py   # asignación izquierda/derecha
```
