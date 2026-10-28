# 19. Integración final: diseño de Lucía, funciones de Xavier y avatar de la dueña

Rama: `integracion-final`, sale de `integracion-anny` (9d4b4f0). No se tocó `main`, `karim`, `integracion-anny` ni las ramas de nadie.

## Decisiones de la dueña (2026-10-27)

| Tema | Decisión |
|---|---|
| Lucía (`main`, PR #3) | Solo el **diseño**: los textos y la lógica son los de `integracion-anny`. |
| Xavier (`integracion-anny`) | Base de todo: Android, cámara, privacidad, memoria, reconocimiento, visor modular. |
| Alcance del diseño | El estilo de Lucía en **toda la app**, a través del tema central. |
| Visor del avatar | El de Xavier, con las mejoras de la auditoría de movimiento del 2026-10-20 portadas. |
| Modelo del avatar | `MODELO_UNIVOZ_v0.vrm` (el de la dueña). |

## 1. Diseño

- **`senas_core/lib/tema_univoz.dart`** lleva la paleta del rediseño:
  - morado `#791FC1`, tinta `#29232F` y fondo blanco;
  - tarjetas planas con borde de 2 px y radio 10;
  - botones con radio 10, siempre de 48 dp de alto como mínimo;
  - deslizadores finos y campos con borde suave.
- **Versión oscura** derivada de esa paleta.
- **Estados verde / ámbar / rojo** como `ThemeExtension` (`EstadosUnivoz`), en claro y oscuro.
- **`senas_core/lib/componentes_univoz.dart`** reúne las piezas del diseño: `TarjetaUnivoz`, `EncabezadoSeccion`, `AjusteDeslizador`, `AjusteInterruptor` (un `SwitchListTile`), `AvisoUnivoz`, `FichaDato`, `IconoCaja`, `AccionFila` y `ProgresoUnivoz`. Todas leen el tema.
- **Ajustes, Sincronizar y Captura** tienen el diseño de Lucía montado sobre la lógica de Xavier. Se conservan:
  - en Ajustes: consentimiento, *Borrar mis datos*, compartir sesión y errores (modo desarrollador) y valores por defecto de `dtw.dart`;
  - en Sincronizar: la confirmación antes de reemplazar con un diccionario más chico, `mensajeHumano` y las secciones de desarrollador;
  - en Captura: la sesión automática con consentimiento y el espejo de la cámara frontal.
- **Resto de la app** (Aprender, Lección, Comunicarse, Acerca, inicio y perfiles): los colores de marca fijos (`#6C63FF`, `#1A1A2E`, …) pasan a `ColoresUnivoz`. Los colores con significado no cambian: los de cada perfil, el acento rosa y la tarjeta oscura del inicio.
- **Conflictos de solo texto.** En 8 de los 11 archivos que tocó Lucía, el único cambio era pasar de "vos" a "tú", y Xavier ya lo había hecho. Se quedaron como están en `integracion-anny`.
- **`ImmersiveNavigation` quedó fuera.** Lucía la importa en Captura, pero el archivo no está en ninguna rama; cuando lo suba, se envuelve el `Scaffold` de `pantalla_captura.dart`.

## 2. Avatar

| Cambio | Dónde | Por qué |
|---|---|---|
| Modelo `MODELO_UNIVOZ_v0.vrm` | `univoz/pubspec.yaml`, `avatar_bridge.dart`, visor, `editor_pose.html` | Decisión de la dueña. `univozM.vrm` queda en el repo sin empaquetar. |
| `separarCuerpo`, `separarManos` y `replayEstable` encendidos | `index.html` (`cal`) | La tabla del torso se midió en este modelo. |
| Sin volteo de la palma por el CMC | `orientarMuneca` | Con landmarks 3D, índice→meñique ya fija el lado del pulgar; voltear por el CMC giraba la palma 180° en ~20% de las señas. |
| `repararVolteosPalma` | `rig_replay.mjs` | Repara volteos de palma de pocos cuadros en los datos (>60° en 1/30 s): rellena por interpolación o sostiene el último cuadro bueno. Solo toca la forma, nunca alturas ni presencia. Tiene paridad con la referencia en Python. |
| `anticiparManos` | `rig_replay.mjs` | Una mano que entra a media seña empieza a viajar 300 ms antes, con la pose de su primer cuadro real; ningún cuadro real cambia. |
| Entrada sostenida de 320 ms | `arrancarReproduccion`, `animar` | El cuadro 0 se sostiene mientras el cuerpo llega desde la pose actual. Antes la seña arrancaba con el brazo en reposo. |
| Crossfade de 300 ms al aparecer un brazo a media seña | `animar` (reproducción) | Antes entraba de golpe si su brazo no estaba marcado en reposo. |

ManoIK sigue **sin conectar**: el solucionador de dedos de Xavier dio errores por articulación iguales o menores (ver `dedos.py`).

### Medición

Se midió con `univoz/herramientas/auditoria_manos`, sobre las 541 señas con reloj simulado, en el mismo modelo antes y después:

| Medida | Antes | Después |
|---|---|---|
| Entrada desde reposo, velocidad pico (p50) | 5.3 m/s | 2.3 m/s |
| Mano que aparece a media seña (p50) | 16.6 m/s | 2.5 m/s |
| Peor error de muñeca por seña (p50 / p99) | 11.6 / 37.9 cm | 2.2 / 10.0 cm |
| Palma, error típico por seña (p99) | 62.9° | 27.6° |
| Latigazos de palma >30° en 1/60 s | 354 | 76 |
| Compuerta congelada | 508 veces en 215 señas | 37 veces en 21 |
| Frases (40), velocidad pico p90 / máx | 22.8 / 29.6 m/s | 4.2 / 5.3 m/s |

Los latigazos que quedan vienen de volteos largos en los datos, que no se pueden reparar desde los puntos. Están en `datos_malos.py` y hay que regrabar esas tomas.

## 3. Pruebas

| Prueba | Resultado |
|---|---|
| `rig-tests` (Node) | 260 de 260. Incluye `rig_volteos.test.mjs` (nueva). `motion.test.mjs` se actualizó a la regla nueva: `orientarMuneca` no pasa el CMC. |
| Python de `senas_core/tools` | 58 de 58, más `test_norm` y `test_dtw` |
| `inline_viewer_modules.py --check` y `sincronizar_kotlin.py --check` | OK |
| `tema_univoz_test.dart` | Actualizada a la paleta nueva, con prueba de los estados |
| `flutter analyze` y `flutter test` | **Se corren en la PC de la dueña** (Flutter no se puede instalar en el entorno donde se armó la rama) |

## 4. Pendiente

- `flutter analyze` y `flutter test` en `senas_core` y `univoz`, y una prueba en el teléfono.
- Lucía: subir `immersive_navigation.dart`.
- Licencias: `Model_Yuki_N.vrm` declara *Redistribution_Prohibited* y está en un repo público. Recomendación: sacarlo del repo.
