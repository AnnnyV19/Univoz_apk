# Auditoría UNIVOZ — ECC 2.2.2

Fecha: 2026-09-24

## Resultado

Se integró flujo de trabajo ECC para diagnóstico, pruebas, cambios aislados y verificación.
`ecc:repo-scan` no se ejecutó: requiere bootstrap externo y quedó pendiente por decisión del plan.

Cambios principales:

- Cámara Android: sesiones idempotentes, cancelación de arranques concurrentes, suscripción a EventChannel antes de iniciar CameraX, mapeo seguro de errores, watchdog de primer frame y liberación de textura.
- Estados observables: detenida, inicializando, enlazada, lista y error.
- Web: almacenamiento en memoria; cámara y avatar con guardas Android-only; fallbacks visibles; sin `path_provider`, MethodChannel o `WebViewWidget` en web.
- Navegación: limpieza de TTS/STT no bloquea rutas; guards `mounted`; tests smoke reales.
- Supabase: errores HTTP ya no exponen cuerpos internos; lectura RLS limitada a muestras aprobadas; landmarks pendientes no son legibles.
- Contratos: retiradas expectativas HTML obsoletas de `sMuneca` y del contador Flutter.

## Evidencia automatizada

Verde:

```text
senas_core/flutter test       45 tests
univoz/flutter test           2 tests
senas_core/flutter analyze    No issues found
python3 tools/test_norm.py    todo en orden
python3 tools/test_dtw.py     todo en orden
univoz/flutter build web      Built build/web
```

`univoz/flutter analyze` queda con 49 infos preexistentes/no bloqueantes; sin errores.
El build web emite avisos WASM dentro de `flutter_tts`, dependencia externa.

QA CUA sobre build web release: bienvenida, propósito, configuración, cámara, agregar muestras, espejo, avatar, ajustes y sincronización. Cámara, captura, espejo y avatar muestran fallback Android-only sin spinner infinito ni pantalla roja.

## Bloqueos de verificación

- `flutter build apk --debug` no puede ejecutarse en este entorno: no existe Android SDK.
- No hay dispositivo Android USB/emulador conectado; quedan pendientes preview real, permiso concedido/denegado/permanente, cámara ocupada, frontal/trasera, background/resume y primer frame en hardware.
- Chrome CLI no está instalado; QA web se ejecutó con navegador in-app CUA sobre `web-server` release.
- iOS queda posterior: no hay cámara nativa en el puente y `Info.plist` solo declara micrófono, no `NSCameraUsageDescription`.

## Seguridad y privacidad

- No se guardan video, audio ni landmarks durante telemetría de cámara.
- APK usa clave publishable; no se detectó `service_role` ni `sb_secret` en configuración de runtime.
- Storage raw permanece privado y solo tiene política de inserción con ruta restringida; no hay lectura/borrado desde cliente.

