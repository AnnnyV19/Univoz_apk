# Contratos y datos

## `LandmarkFrameV1`

Contrato crudo compartido por captura, preview y normalización:

| Campo | Forma | Regla |
|---|---|---|
| `t` | entero ms | creciente por stream |
| `pose` | 33 × `[x,y,z,visibility]` | imagen; preview |
| `poseMundo` | 33 × `[x,y,z]` | metros aproximados; normalización |
| `left` | 21 × `[x,y,z]` o `null` | mano anatómica izquierda |
| `right` | 21 × `[x,y,z]` o `null` | mano anatómica derecha |

La Z de pose de imagen es profundidad relativa monocular y no debe gobernar
reconstrucción corporal. `poseMundo` se usa cuando está disponible y supera
validaciones de consistencia.

## `MotionFrameV2`

Invariante:

```text
norm_version = "2.0.0"
frame_dim = 152
t_frames = 32
```

Layout actual:

| Rango | Dimensiones | Contenido |
|---:|---:|---|
| 0–23 | 24 | cuerpo: 8 puntos × XYZ en marco corporal |
| 24–26 | 3 | ubicación muñeca izquierda |
| 27–29 | 3 | ubicación muñeca derecha |
| 30 | 1 | presencia mano izquierda |
| 31 | 1 | presencia mano derecha |
| 32–91 | 60 | forma izquierda: 20 puntos × XYZ |
| 92–151 | 60 | forma derecha: 20 puntos × XYZ |

Una muestra completa tiene `32 × 152` valores. El empaquetado float16 ocupa
aproximadamente 9.5 KB.

## Normalización

1. Origen en el punto medio de hombros.
2. Escala por ancho de hombros.
3. Marco corporal que absorbe traslación, escala e inclinación.
4. Forma de mano relativa a muñeca y escalada por mano.
5. Ubicación de muñeca conservada porque es información fonológica.
6. Orientación de palma no se elimina: distingue señas.
7. Z de pose no se usa como profundidad confiable.

Cambiar esta fórmula exige subir versión, regenerar golden, recalcular datos y
revisar modelos. No editar índices para “agregar” cabeza, confianza o
profundidad.

## Metadatos fuera del vector

Pueden viajar aparte:

```json
{
  "motion_frame": [0.0],
  "meta": {
    "confidence": 0.93,
    "left_hand_state": "TRACKING",
    "right_hand_state": "OCCLUDED",
    "timestamp_ms": 123456789
  }
}
```

El bloque `meta` no cambia `frame_dim`. Rostro y profundidad futura deben tener
contratos propios y versión explícita.

## `SignSpaceFrame` v1 (avatar y biblioteca)

Contrato aparte de `MotionFrameV2`: no lo reemplaza ni cambia sus 152
valores. Separa la seña del cuerpo de quien la hace para que el avatar la
copie o reproduzca con sus propias proporciones. Implementación canónica
`senas_core/tools/sign_space.py`; espejos `lib/sign_space.dart` y
`assets/avatar_viewer/rig_sign_space.mjs`; golden
`test/golden/sign_space_cases.json` (tolerancia `1e-5`).

| Offset | Tam. | Contenido |
|---|---|---|
| 0 / 6 | 3 | Dirección unitaria hombro→codo izquierdo / derecho |
| 3 / 9 | 3 | Dirección unitaria codo→muñeca izquierda / derecha |
| 12 / 15 | 3 | Centro de palma izq. / der. (anchos de hombro) |
| 18 | 3 | Ancla nariz |
| 21 | 3 | Ancla boca |
| 24 / 27 | 3 | Dirección muñeca→nudillos izq. / der. |
| 30 | 5 | Contactos 0/1: cara izq., cara der., pecho izq., pecho der., manos |

- Marco del cuerpo igual que 152D: `+x` derecha de la persona, `+y` arriba,
  `+z` al frente, origen en el centro de hombros.
- `mode`: `full` (vertical desde caderas) o `upper` (caderas no visibles:
  vertical de la cámara; sentado, silla de ruedas, medio cuerpo).
- `mask`: `armL`, `armR`, `handL`, `handR`, `face`. Un bloque enmascarado
  vale `0.0` y la máscara, no el valor, dice que no existe.
- Viaja en `sourceMeta.sign_space` (Android → visor) y, en biblioteca, como
  campo opcional `sign_space` (+ `sign_space_version`) de `MotionSequenceV2`,
  un frame o `null` por cada frame 152D. Lectores viejos lo ignoran.

## `BodyProfileV1` y `CapabilityMask`

Medianas de ancho de hombros, brazo, antebrazo, mano y cuello por lado
(metros), alcance máximo observado (`rom`) y capacidad por miembro
(`ok`, `partial`, `not_observed`, `absent`). `absent` solo puede venir
declarado por el usuario: la cámara no distingue ausente de fuera de cuadro.
Se estima con Fast User Capture (3 poses guiadas) tras consentimiento
explícito; se guarda local (`univoz.bodyProfile.v1` en web), versionado y
borrable. Nunca guarda video ni landmarks: los frames se descartan al
terminar la estimación.

## Backend y almacenamiento

- Flutter reconoce offline con DTW.
- AI Engine opcional acepta `MotionSequenceV2`.
- SVM/kNN se entrenan fuera del APK.
- No poner service keys en la aplicación.
- Video no se guarda.
- Landmarks crudos persistentes solo bajo acción explícita y con propósito de
  diagnóstico/ingesta.
