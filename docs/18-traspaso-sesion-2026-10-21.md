# Traspaso de sesión — 2026-10-21

Estado al cerrar la sesión para retomarlo en la siguiente.

## Ramas

| Rama | Commit | Qué tiene |
|---|---|---|
| `KARIM` (→ `origin/karim`) | 9755c5d | Beta Android 0.9.0 (T0–T10) + arreglos N1–N3. Tag local `beta-0.9.0-pre-merge` en 0f64fba. **Tiene el cierre de cámara en release** (ver abajo); el arreglo vive solo en `integracion-anny`. |
| `integracion-anny` (→ `origin/integracion-anny`) | d6e8e03 + commit de esta sesión | Unión de KARIM con el trabajo de la dueña (`origin/app-limpia`, re-emparentado como `anny-sobre-base` 2be80df sobre 7c774e5). Detalle en `docs/17-integracion-app-limpia.md`. Aquí van los arreglos de cámara/carga/memoria de este traspaso. |

Para converger: la dueña debe trabajar sobre `integracion-anny` (o lo que se fusione a `karim`), editar el visor en `senas_core/assets/avatar_viewer/` y regenerar (`inline_viewer_modules.py`), y no editar las copias generadas (index.html de univoz, LandmarkPlugin.kt de univoz).

## Arreglado en esta sesión (commit en `integracion-anny`)

1. **Cierre al abrir la cámara (release)**: R8 renombraba Flogger (logger de MediaPipe) y `Graph.<clinit>` lanzaba `ExceptionInInitializerError: no caller found on the stack`. Arreglo: `-keep class com.google.common.flogger.**` en `univoz/android/app/proguard-rules.pro`. Verificado en el S22+: 0 cierres tras instalar.
2. **Traba al abrir la cámara**: `LandmarkEngine` (modelos + GPU, ~1 s) se creaba en el hilo principal. Ahora se crea en el ejecutor y `enlazar()` sigue en el principal (`LandmarkPlugin.kt`). Fallos `Throwable` de MediaPipe → error `mediapipe_init` con texto amable, no cierre.
3. **Estado de carga**: `senas_core/lib/reconocer/carga_camara.dart` ("Preparando la cámara…", pista a los 4 s).
4. **Memoria del diccionario (541 señas, 51 MB)**: un solo `Diccionario` compartido e invalidado al grabar/borrar/sincronizar; aprendizaje sin `Template` completos; `segs` en `Float64List`; espejos recalculan `seq`. Escritorio: 2ª pantalla +427 MB → 0; total con 2 pantallas ~1.2 GB → ~0.5 GB. Informe: `.superpowers/sdd/en-esta-sesion-nos-sequential-neumann/carga-report.md` (git-ignored, local).
5. **Sync de plantillas**: ya no lee los 51 MB en cada arranque para contar; guarda la hora del intento aunque sea inválido; textos de `pantalla_sync` corregidos.
6. **`SuavizadorLandmarks.filtrar`** conserva todos los campos del frame (`imageAspect`, etc.) → pistas de encuadre correctas en horizontal.
7. **Sesión de cámara global** (`static int _session` en `CameraBridge`): antes la primera cámara de cada pantalla nueva se cancelaba ("El inicio de cámara fue cancelado"). Test `senas_core/test/camera_sesion_test.dart`.
8. **Diccionario sin paquete no se queda en caché** si leer el asset falla (poca memoria).

## Pendiente para la siguiente sesión

- **Medir en el teléfono** la memoria con la versión nueva (antes: 1.4 GB PSS con Reconocer abierto, `adb shell dumpsys meminfo com.univoz.app`). Recorrido: Comunicarse → Traducir señas → señas → atrás → volver a entrar (verifica el arreglo 7).
- Instalar la build con los arreglos 7 y 8 (la del teléfono, 06:20, aún no los tiene): build release con la llave de prueba y `adb -s RFCT60VQ0QZ install -r`.
- Minor de la revisión (`review-carga.md`, local): motor construido para sesión ya cancelada (M1), `enlazar` no libera engine/entry previos (M2), motor huérfano en `aplicarNivel` (M3), versión del diccionario subida tras escritura fallida (M4), hora de intento en el futuro (M5), ~200 MB retenidos todo el proceso (M6), caché estática de `visor_sena` sin invalidar (M7), etiqueta de carga leída dos veces por lector de pantalla (M8), texto "el diccionario" en diálogo de sync (M9).
- Probar umbrales nuevos (0.50 / 0.32) en el teléfono con Reconocer; Aprender/Lección/Acerca usan violetas propios, no el tema (contraste sin revisar); falta botón "reiniciar mi progreso".
- Piezas del visor de la dueña apagadas: separadores cuerpo/manos (tabla medida sobre su VRM), `replay_estable`, ManoIK sin conectar.
- Remoto: Supabase tiene ~146 plantillas vs 541 del paquete; aplicar `senas_core/sql/006_beta_limites.sql` y `007_video_url.sql`; verificar insert anónimo de `sign_samples` con `curl`.
- Release: crear keystore real (`docs/RELEASE.md`), correo de contacto y URL pública de la política de privacidad.

## Para confirmar con la dueña (bloquea repartir el APK)

- **Licencias**: `MODELO_UNIVOZ_v0.vrm` y `Model_Yuki_N.vrm` declaran `Redistribution_Prohibited` en sus metadatos; `aprendizaje.json` deriva del glosario de INDISCAPACIDAD CDMX (autorización no confirmada); `plantillas.json` y la obligación CC BY-SA 4.0 de Wikisigns.
- Modelo VRM oficial (hoy `univozM.vrm` por defecto).
- Cuál `plantillas.json` es canónico (se dejó la copia de `univoz/assets`, 1296).
- Política 006: ¿exigir `video_url IS NULL` para el rol anónimo?
