# UNIVOZ: señas (LSM)

App Flutter de comunicación con Lengua de Señas Mexicana: reconocimiento de señas con la cámara
(MediaPipe + DTW) y avatar 3D (VRM) que hace las señas, con diccionario y frases.

## Carpetas
- `univoz/`: la aplicación (pantallas, assets del avatar y `plantillas.json`).
  Se corre desde aquí: `flutter pub get` y `flutter run`.
- `senas_core/`: paquete compartido (normalización `sign_norm`, reconocimiento DTW, avatar,
  diccionario). `univoz` lo usa con `path: ../senas_core`.
- `senas_core/tools/`: scripts de Python para importar datasets, aprobar muestras y exportar
  `plantillas.json` (necesitan un `.env` propio; ver `.env.example`).
- `univoz/herramientas/cuerpo/`: pruebas del avatar (separadores de cuerpo y manos, frases).

## No se versiona
`.env` (claves), `build/`, `.dart_tool/`, videos y `datasets_lsm/`, respaldos `_respaldo*`.
