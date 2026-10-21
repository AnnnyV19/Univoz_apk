# 17. Integración del trabajo de la dueña (`app-limpia`) en la beta Android

Rama de integración: `integracion-anny` (sale de `KARIM`; `KARIM` no se tocó).

## 1. Qué se integró y de dónde sale

| | Commit |
|---|---|
| Nuestra rama | `KARIM` 9755c5d (beta 0.9.0 + fixes; tag `beta-0.9.0-pre-merge` en 0f64fba) |
| Trabajo de la dueña | `origin/app-limpia` fd43dc5 (commit raíz huérfano, autora AnnyV19) |
| Su árbol re-emparentado | `anny-sobre-base` 2be80df: el mismo árbol de fd43dc5 con padres `7c774e5` y `fd43dc5` |
| Base real común | `7c774e5` "logo de univoz" (2026-09-29, cabeza de `origin/Lani`) |

`app-limpia` es un commit huérfano: parte de un *snapshot* del 29-sep, por eso Git no podía
proponer un PR ni un merge limpio. No "borró" `backend/`, `docs/`, `scripts/`, el visor modular, la
firma de release, SOS/TTS/dictado, la privacidad, etc.: nunca los tuvo. Re-emparentando su árbol
sobre `7c774e5` el merge es de tres vías reales (20 conflictos de texto en vez de cientos de
add/add), y todo lo que solo cambió uno de los lados entró solo.

### Quién gana por área (regla aplicada)

| Área | Gana | Notas |
|---|---|---|
| Android nativo: Kotlin, manifest, gradle, `applicationId com.univoz.app`, R8, firma, recorte de assets | Nosotros | La copia de `LandmarkPlugin.kt` en `univoz/` se regeneró con `sincronizar_kotlin.py` (la suya mandaba `iw`/`ih`; nosotros `image_w`/`image_h`) |
| Puente del avatar: cola, `EstadoAvatar`, `VistaAvatar`, reintentar, timeout | Nosotros | Se le agregaron `encuadrar()` y `reproducirFrase()` encima de la cola (ver 2.3) |
| `camera_bridge`, `controlador_captura`, persistencia (`escritura_atomica`, muestras, perfil, sesiones por partes) | Nosotros | Se le agregaron `CamaraIniciada.frontal`, el suavizador One Euro del esqueleto dibujado y la isotropía al terminar la captura |
| UI `reconocer/`, tema, modo desarrollador, "tú", PRIVACIDAD, SOS/TTS/dictado | Nosotros | |
| Pesos y umbrales DTW, normalización nueva (forma isotrópica, ubicación centrada, prefiltro de 8 tramos, espejo automático) | Suyo | El aspecto sale de **nuestro** `imageAspect` (no se agregó su `aspecto`) |
| Diccionario (`plantillas.json` 541 señas, `aprendizaje.json`) | Suyo | Ver 2.2 y 4 |
| Pantallas Aprender, Lección, `visor_sena`, currículo, progreso, descripciones, Acerca y créditos | Suyo | Adaptadas a `VistaAvatar` y a "tú" |
| `pantalla_avatar`: lista con filtro, velocidad, frases (`frase_a_senas`, `avatar_toma`) | Suyo | Con nuestros guardas (`compatible`, `kIsWeb`, try/catch, avisos) |
| Vista espejo de la cámara frontal | Suyo | Solo presentación; reconocimiento y avatar no se voltean |
| Herramientas Python de ingesta, `.bat`, `GUIA.md`, `herramientas/cuerpo` | Suyo | |
| Visor 3D (`index.html` generado) | Nosotros + sus bloques portados | Ver 3 |
| Modelo VRM | Nosotros (`univozM.vrm`) | El suyo se conserva como opción, ver 5 |
| `.gitignore` | Unión | Se conservaron `key.properties`, `*.jks`, `*.keystore` |

## 2. Resoluciones de los conflictos

### 2.1 Triviales
`.gitignore` (unión), `README.md` (el nuestro y, debajo, el suyo como "Resumen de la app"),
imports de `pantalla_ajustes`, pruebas de ambos lados en `dtw_test`, `sign_norm_test`, `test_norm.py`,
`widget_test` (la suya se sumó al `MyApp` real), `web_camera_contract_test` (la nuestra).

### 2.2 Reconocimiento y diccionario
* `dtw.dart` / `tools/dtw.py`: sus pesos (`kWBody 0`, `kWLoc 0.75` sin posición absoluta, `kWPres 0.25`,
  `kShapePenalty 0.15`) y umbrales `0.50 / 0.32` (`kVersionUmbrales = 3`: los umbrales guardados con la
  escala vieja se descartan; el resto de los ajustes se conserva).
* `muestras_locales.dart`: `Ajustes.fromJson` combina `version_umbrales` (suyo) con consentimiento y perfil
  corporal (nuestros).
* `plantillas.dart`: se conservó **nuestra** estructura (`PlantillaFuente`, `armarClasificador`, espejo) y
  se reinyectaron sus políticas:
  * el paquete del APK manda; de lo sincronizado solo entran las **glosas que el paquete no trae**
    (`adicionales`). Antes, si había sincronización, reemplazaba al paquete;
  * isotropía de las plantillas sincronizadas (16:9) y de las locales (`aspecto` guardado o el del bitmap);
  * `prefilter` 80 con espejo, 40 sin él;
  * `Diccionario.aprendizaje` (señas solo para Diccionario/avatar, nunca al clasificador).
* **Ruling: ids de espejo.** Ella espejaba con el mismo `signId`; nosotros con `<id>#espejo`. Se quedó el
  nuestro (`Prediction.signId` distingue un espejo; no se espeja un espejo).
* **Ruling: aspecto.** `LandmarkFrame.aspectoEfectivo => imageAspect ?? kAspectoAnalisisApp`.
  `CapturaMovimiento.aspecto` es la mediana de `imageAspect`. `terminar({int? hastaMs})` conserva nuestra
  firma y aplica `isotropizarSecuencia`. El suavizador solo toca `frame.value` (lo que se dibuja); el
  reconocimiento y el registro de sesión leen frames sin filtrar.
* **Golden.** `golden_cases.json` se regeneró con `tools/gen_golden.py` (no se mezcló a mano). La
  normalización guardada sigue siendo 2.0.0: la isotropía se aplica al comparar, así que
  `paridad_manos` (JS ↔ Kotlin ↔ Dart ↔ Python) no cambia.
* **Ruling: `tools/test_dtw.py`.** Sus señas sintéticas ya no se distinguían con nuestra normalización: la
  ubicación de la mano sale de la muñeca del esqueleto métrico (`pose_mundo`), que en la prueba era fija,
  y nuestra `hand_usable` rechaza las formas de mano deformadas que ella usaba para diferenciarlas.
  Las señas ahora trazan figuras distintas (frecuencia y proporción propias) y esa trayectoria viaja también
  en `pose_mundo`. Mismas comprobaciones, mismos umbrales.

### 2.3 Puente del avatar y pantallas
* `avatar_bridge.dart`: base nuestra. `encuadrar(modo)` y `reproducirFrase(segmentos)` se registran en la
  cola (`ColaPuenteAvatar.encuadre`) y por `llamadaSegura`, con la misma validación 32×152; en web viajan
  por `postAvatarCommand`. `reproducir` ahora pasa por `_js` (así `AvatarBridge.sinVisor` puede probarse).
* `pantalla_avatar.dart`: su layout con `VistaAvatar` y nuestros guardas. `PantallaAvatar` acepta
  `puente`/`vista` solo para pruebas; su `pantalla_avatar_test.dart` usa `AvatarBridge.sinVisor` en vez de un
  `WebViewPlatform` falso.
* `skeleton_painter.dart`: la pantalla de traducción es nuestra; solo se portó el volteo de la vista frontal
  (`Transform.flip` + `SkeletonPainter(espejo:)`).
* `aprender_screen.dart` (borrado por nosotros como código muerto): se restauró el suyo, que ahora es la
  pantalla principal "Aprender". `visor_sena.dart` usa `VistaAvatar(bridge:)`. `progreso_aprendizaje.json`
  se escribe con `escribirAtomico`, y se añadió a PRIVACIDAD (pantalla y `docs/PRIVACIDAD.md`).

## 3. Visor 3D

`univoz/assets/avatar_viewer/index.html` es un archivo **generado**; se tomó el nuestro. Sus bloques se
portaron a `senas_core/assets/avatar_viewer/` (fuente de verdad) como módulos `rig_*.mjs` y se regeneró con
`python3 senas_core/tools/inline_viewer_modules.py`:

| Módulo | Qué es | Estado |
|---|---|---|
| `rig_frase.mjs` + `rig_replay.mjs` | `window.reproducirFrase`: varias señas seguidas con transición de 0.26 s; interpolación entre cuadros | **Conectado y activo** (lo necesita la pantalla del Diccionario) |
| `rig_encuadre.mjs` | `window.encuadrarCamara('cintura' \| 'codos')`, medidas del modelo, cámara que baja si la seña pide la mano muy abajo | **Conectado y activo** (lo usa Aprender; por defecto `cintura`, como antes) |
| `rig_safety.mjs` | `setMaxAngularVelocity` en la compuerta | Portado, sin uso por ahora |
| `rig_cuerpo.mjs` | `SeparadorCuerpo`: manos, muñecas y codos no atraviesan el torso (nunca cambia la altura de la muñeca) | Conectado, **apagado** (`separarCuerpo: false`) |
| `rig_manos.mjs` | `SeparadorManos`: una mano no atraviesa a la otra | Conectado, **apagado** (`separarManos: false`) |
| `rig_replay.mjs` (`prepararSecuencia`) | relleno de huecos y suavizado gaussiano de la seña | Conectado a las frases con `replayEstable: true`, **apagado** |
| `rig_mano_ik.mjs` | ManoIK: dirección 3D de cada falange | **Portado pero no conectado ni inlineado** (ver abajo) |

Las banderas se leen en `configurarRig` (`separar_cuerpo`, `separar_manos`, `replay_estable`).

**Por qué apagados.** La tabla de cortes del torso de `SeparadorCuerpo` se midió en la malla de
`MODELO_UNIVOZ_v0.vrm`; con `univozM.vrm` hay que regenerarla
(`univoz/herramientas/cuerpo/simulacion/tabla_torso.py`) y validarla en un teléfono antes de encenderlo.
Con las banderas apagadas no corre ningún código nuevo dentro de `resolverBrazo` ni de `aplicarFrame`.

**No portado (decisión).**
* ManoIK está como módulo y con prueba de humo, pero **no está conectado**: reemplaza el solucionador de
  dedos y nuestro `moverMano` cambió bastante (pulgar calibrado, filtros, compuertas). Conectarlo es una
  tarea aparte, con revisión en dispositivo.
* Su "reproducción estable" propia (suavizado de salida por hueso, tiempo continuo, límite de 40 rad/s en
  replay): nuestro visor ya interpola a la tasa de pantalla y tiene su suavizador de salida.
* El *plugin* que acomoda un VRM 1.0 al marco de un 0.0: ambos modelos del repo son 0.0.

**Pruebas.** Todo lo puro vive en `senas_core/tools/rig-tests/` (entra a `npm test` y a
`./scripts/univoz.sh test`): `rig_cuerpo.test.mjs` (200 casos contra la referencia en Python),
`rig_manos.test.mjs` (150 pares), `rig_frase.test.mjs`, `rig_encuadre.test.mjs`, `rig_mano_ik.test.mjs`
y una prueba nueva de `setMaxAngularVelocity`. Los casos de referencia están en
`rig-tests/paridad_cuerpo/`. `prueba_visor.js` y `prueba_visor_manos.js` (en `univoz/herramientas/cuerpo/`)
extraían `resolverBrazo` del `index.html` de la dueña con sus marcas y **no funcionan** con el visor
integrado: quedan como referencia. Además se hizo una prueba de humo manual del visor en Firefox sin cabeza
(carga el VRM, `encuadrarCamara('codos')`, `reproducirFrase`, y las banderas encendidas), sin errores de JS.

## 4. Rendimiento del diccionario (51 MB)

`plantillas.json` pasó de 5 MB a 51 MB (1296 plantillas, 541 señas; con espejo 2592 en el clasificador) y
`aprendizaje.json` suma 11 MB. Cargarlos con `rootBundle.loadString` + `jsonDecode` en el hilo de la
interfaz era un riesgo de ANR/OOM en los equipos de nivel "bajo".

* `cargarDiccionario`, `cargarAprendizaje` y `contarPlantillasPaquete` leen los bytes del asset y hacen el
  parseo, la isotropía, el centrado, las firmas y el armado del clasificador en un isolate (`compute`).
  `contarPlantillasPaquete` (guardia ≥ 50 % de la sincronización) se calcula una vez por ejecución.
* `Template` guarda `seq` y `cseq` como `Float64List` (8 bytes por valor, no ~24 de una lista de `double`).
* Medido en el escritorio (Flutter test, no es un teléfono): contar 0.6 s, cargar todo 1.5 s, el hilo
  principal no se bloquea más de ~110 ms; RSS pico ~710 MB **en el proceso de pruebas completo**, no es la
  cifra de la app. **Falta medir en un equipo "bajo"** con `DeviceTier` (ver sección 6).
* **Sincronización.** La base remota tiene ~146 plantillas (44 señas): contra 1296 la guardia ≥ 50 %
  siempre descarta la descarga ("demasiado chica"), que es lo correcto (no baja el diccionario). En cuanto
  la base tenga las 541 señas, la sincronización vuelve a funcionar y solo aporta glosas nuevas.
* **Empaquetado.** `exportar_paquete.py` escribe en `senas_core/assets/plantillas.json`; las dos copias
  habían divergido (1296 en `univoz/assets`, 1269 en `senas_core/assets`, mismas 541 glosas; la de
  `univoz` incluye las letras que aplicó `aplicar_letras_v4.py`). **Ruling:** manda la de `univoz/assets`
  y se copió a `senas_core/assets` (un solo blob en git). El gradle de `univoz` sigue excluyendo
  `**/packages/senas_core/assets/**`, así que el APK no la lleva dos veces.
* `univoz/pubspec.yaml` conserva nuestra lista recortada de assets y suma `assets/aprendizaje.json`.
* Formato más compacto (el paquete en f16 + base64 como `aprendizaje.json`, ~17 MB en vez de 51) **no se
  hizo**: toca `exportar_paquete.py`, `curar_plantillas.py`, la lectura y sus pruebas. Es la mejora
  recomendada si la medición en un teléfono bajo sale mal.

## 5. Modelo VRM

Se conservan `univozM.vrm` (lo usan `avatar_bridge`, el visor web y todo el rig afinado y los gates) y
`Model_Yuki_N.vrm` (como estaban), y se añadió `univoz/assets/avatar/MODELO_UNIVOZ_v0.vrm` (15 MB)
**sin declararlo en `pubspec.yaml`** (comentado) para no sumar 15 MB al APK de un modelo sin validar.
`_kRutaAvatar` y el nombre de diagnóstico siguen siendo `univozM`. Se restauró `correr_univoz.bat`.
Para probar el modelo de la dueña: descomentar la línea del `pubspec`, cambiar `_kRutaAvatar`, correr
`paridad_manos` y los gates de rig, y regenerar la tabla del torso.

## 6. Qué debe confirmar la dueña

1. **Cuál es el modelo VRM oficial** (`MODELO_UNIVOZ_v0.vrm` o `univozM.vrm`) y si podemos revalidar el rig
   con él. Su tabla del torso se midió en el suyo.
2. **Licencias.** *INDISCAPACIDAD CDMX*: la pantalla Acerca dice "uso autorizado", pero el glosario indica
   que "su reproducción requiere autorización" → confirmar que existe y que cubre un APK de la beta
   pública. *Wikisigns* es CC BY-SA 4.0: la obligación de compartir igual alcanza al derivado
   (`plantillas.json`); confirmar cómo se cumple. CICESE, ITESO-MX-100 y UAEMex (CC BY 4.0) piden
   crédito y decir si hubo cambios (la pantalla Acerca lo cubre; revisar el texto).
3. **`video_url`.** Sus herramientas crean `sign_samples.video_url` y la vista `v_muestras_revision` con la
   clave de servicio, fuera de `sql/`. Se documentó en `senas_core/sql/007_video_url.sql` (idempotente).
   Decidir si se aplica ya y si la política de INSERT de `006_beta_limites.sql` debe exigir
   `video_url IS NULL` para el rol anónimo (nota en el propio 007).
4. **Cuál `plantillas.json` es el canónico** (se asumió el de `univoz/assets`, 1296) y que la base remota se
   va a actualizar al diccionario de 541 señas, o la sincronización seguirá descartándose.
5. **Calibración.** Los umbrales 0.50 / 0.32 y los pesos salen de su validación cruzada con sus datos; los
   ajustes guardados en teléfonos de la beta se resetean. Falta un caso físico con la UX `reconocer/`
   (HOLA, letras) para ver cómo se siente el margen nuevo.
6. **Memoria.** Medir carga y RAM con 541 señas en un teléfono de nivel bajo (ver sección 4).
7. **Avance de Aprender.** No hay botón "Reiniciar mi avance" en la UI (el método existe); hoy se borra con
   "Borrar datos" de Android o al desinstalar (así lo dice PRIVACIDAD).
8. **Tema y accesibilidad de Aprender.** Usa colores propios (violeta) y no pasa por `tema_univoz.dart`; no
   se revisó el contraste. Pendiente.

## 7. Cómo trabajar de aquí en adelante (un solo punto de convergencia)

* **Base:** `origin/karim` o la rama integrada (esta). Nunca volver a subir un *snapshot* de la carpeta:
  `git fetch && git switch -c anny/mi-cambio origin/karim`, y PR/merge hacia `karim`.
* **El visor se edita en `senas_core/assets/avatar_viewer/`** (los `rig_*.mjs` y el `index.html` fuente) y
  se regenera con `python3 senas_core/tools/inline_viewer_modules.py`. **No** se edita a mano
  `univoz/assets/avatar_viewer/index.html`.
* **El Kotlin de la cámara se edita en `senas_core/android/.../com/univoz/senas/`** y se copia con
  `python3 senas_core/tools/sincronizar_kotlin.py`. **No** se edita `univoz/android/.../LandmarkPlugin.kt`.
* `plantillas.json`: una sola fuente (`univoz/assets/`), copia a `senas_core/assets/` al exportar.
* No subir el VRM de 15 MB cada vez que cambia (git-lfs o *release asset*).
* `key.properties`, `*.jks`, `*.keystore` siguen ignorados.
* Antes de cada push: `./scripts/univoz.sh test` (Flutter, Python, backend, gradle, Kotlin y visor
  sincronizados, pruebas geométricas de `rig-tests`, `git diff --check`).
* Si cambia la normalización que afecta la captura: JS primero → regenerar `paridad_manos` →
  Kotlin/Dart/Python → `gen_golden.py`.
