# RigBody, IK y retargeting VRM

## Principios

- Las posiciones de usuario no se aplican directamente sobre huesos VRM.
- El avatar tiene longitudes, ejes y pose de reposo propios.
- Orientación interna: cuaterniones.
- Dedos: ángulos locales por segmento.
- Brazos: objetivo de muñeca + plano/polo de codo.
- Ningún candidato llega al avatar sin pasar `Safety Gate` por unión.

## IK de dos huesos

Entradas:

```text
S = hombro
T = objetivo de muñeca
P = polo de codo
a = longitud del brazo superior del avatar
b = longitud del antebrazo del avatar
```

1. Clampear `d=|T-S|` a `|a-b|+ε ... a+b-ε`.
2. Obtener el ángulo con ley de cosenos.
3. Proyectar el polo sobre el plano perpendicular a `T-S`.
4. Resolver el codo en el lado indicado por el polo.
5. Resolver antebrazo contra el objetivo ya clampeado.
6. Aplicar límites y continuidad temporal.

El objetivo clampeado debe usarse para upper arm y lower arm. Usar el objetivo
original en una sola parte estira el brazo de forma imposible.

## Límites

Valores iniciales:

- codo: aproximadamente `0°–145°/150°`;
- muñeca: flexión/extensión y desviación limitadas;
- hombro: elevación y twist limitados;
- falange: tope por segmento;
- pulgar: rango separado.

Los límites del rig son aproximaciones de seguridad, no diagnóstico médico.
Exponer ajustes solo cuando faciliten calibración visual.

## Cuaterniones

Para cada nueva orientación:

```javascript
if (dot(q_prev, q_new) < 0) q_new = negate(q_new);
q_out = slerp(q_prev, q_new, alpha);
```

Usar `nlerp` cuando el ángulo sea pequeño y rendimiento sea más importante.
Separar `swing` y `twist` en antebrazo/hombro si el rig presenta torsión.

## Safety Gate

`rig_safety.mjs` valida finitud, quaternion, timestamp, `frameId`, padre,
longitud ósea, límites, velocidad angular, etapa e identidad de mano antes de
escribir `rotation` o `quaternion`. Códigos incluyen
`non_finite_transform`, `invalid_quaternion`, `bone_length_drift`,
`joint_limit_violation`, `quaternion_flip`, `stale_frame`,
`hand_identity_swap`, `parent_frame_mismatch` y `stage_desync`.

Estado por unión: `VALID → FROZEN → RECOVERING → VALID`. Rechazo conserva la
última pose local y no congela otras uniones. Recuperación mezcla gradual por
tiempo (`recoveryMs`, 100 ms en el visor; sin la opción, tres frames); prueba
sintética confirma que escritor no aplica NaN.

Desde 2026-10-19 (docs/14 H2, H8) el visor pasa:

| Opción | Valor | Efecto |
|---|---|---|
| `maxAngularVelocityRadS` | 20 | límite por `dt` |
| `maxStepRad` | 100° | giro más rápido que el límite se **recorta** (avanza a velocidad máxima, anomalía `angular_velocity_clamped`) en vez de congelar |
| `palmFlipRad` / `palmFlipConfirmFrames` | 120° / 2 | salto enorme en `*:hand` = `palm_flip` (rechazo); si la pose nueva se repite 2 frames es volteo real y entra por recuperación (`palm_flip_confirmed`) |
| `angularDeadbandRad` | 1.5° | zona muerta suave: bajo el umbral avanza `(delta/umbral)²` del camino; atenúa temblor sin escalones (retraso estable ≈ 1° en movimiento lento) |
| `boneLengthMode` | `'audit'` | `bone_length_drift` se registra sin congelar hasta medirlo en sesión real |
| `maxAgeMs` | 200 | edad desde la **llegada** al visor: `nowMs = timestampMs + (ahora − llegada)` (`receivedAtMs` en `metaRigFrame`). No desde la captura: con "último frame gana" un frame lento sigue siendo el más nuevo, y medir latencia de captura congelaría todo en equipos lentos |

La longitud ósea del brazo se compara contra la mediana de las últimas 30
medidas del mismo segmento (una por frame); antes se pasaba la longitud del
rig como referencia y como medida y el chequeo nunca fallaba. Los ajustes
aceptados se cuentan aparte (`safety_adjustments` en el evento `perf`).

## Estados del avatar y transiciones

`rig_avatar_state.mjs` describe el estado (`REST`, `TRACKING`, `HOLD`,
`RETURNING`, `NO_SIGNAL`, `PLAYBACK`; prioridad en ese orden inverso) y mezcla
cuaterniones en el tiempo. El estado se ve en el panel (`avatar …`) y se
registra en la sesión como evento `avatar_state` solo al cambiar.

- Volver a reposo (mano perdida tras 250 ms de gracia, brazo sin datos,
  stream > 450 ms sin frames, cámara apagada, fin de reproducción) ya no es
  de golpe: se escribe el reposo como antes (compuertas y estado iguales), se
  lee esa pose y se mezcla desde la previa en 250 ms (smoothstep).
- Reposo o reproducción → pose nueva entra con crossfade de 150 ms desde la
  pose actual. Un hueso que el tracking vuelve a escribir sale de la mezcla de
  reposo: manda el tracking.
- `?transiciones=0` vuelve al comportamiento de golpe para comparar.

## Suavizado de salida (render)

La pose que escribe el tracking solo cambia cuando llega un frame de cámara
(15–30/s); el render va a 60–144 Hz. Sin suavizar, el avatar avanza a saltos:
en la sesión `dnrzh8` solo el 25 % de los renders movía la pose. Cada render,
después de compuerta, filtros y transiciones, cada hueso avanza hacia la pose
escrita con `alpha = 1 − exp(−dt/tau)` (por tiempo, igual a cualquier FPS):

| Grupo | `tauMin` / `tauMax` | Distancia "rápida" | Tope de velocidad |
|---|---|---|---|
| cuerpo (cadera, columna, hombros) | 40 / 90 ms | 15° | 360°/s |
| brazo (`UpperArm`, `LowerArm`) | 30 / 80 ms | 20° | 900°/s |
| mano (`Hand`) | 30 / 90 ms | 25° | 720°/s |
| dedos | 15 / 45 ms | 20° | 1440°/s |

`tau` baja de `tauMax` (distancia chica = temblor, mucho suavizado) a `tauMin`
(distancia grande = movimiento real, poco retraso). El tope de velocidad hace
que un volteo o un salto de IK se vea como giro rápido. Cabeza y cuello no
entran (la cara ya se suaviza por render). Un hueso en transición de reposo no
se suaviza dos veces; durante una plantilla el suavizado solo sigue la pose.
Con el suavizado activo no hace falta crossfade al volver al vivo (sigue
para iniciar plantillas y con `?suavizado=0`, que lo apaga para comparar). Un
volteo de palma confirmado se recupera en 250 ms (`palmFlipRecoveryMs`) en vez
de 100.

Medido reproduciendo `dnrzh8` (1816 frames reales a 15 FPS, render 60 Hz):

| | Sin suavizado | Con suavizado |
|---|---|---|
| Renders que mueven la pose | 25 % | 100 % |
| Paso máximo por render p95 / máx | 106° / 129° | 15.7° / 19° |
| Jitter mano estática izq / der | 2.73 / 2.17° | 1.82 / 1.30° |
| Jitter antebrazo estático izq / der | 2.31 / 1.85° | 1.61 / 1.37° |
| Retraso añadido (resolución 66 ms) | — | antebrazo ~0, brazo ~40, mano ~65 ms |

## Reproducción de plantillas

`reproducirSecuencia` interpola un frame por render entre los 32 de la
plantilla (152D y SignSpace) solo si ambos frames tienen la misma estructura
(presencia de manos, codos con datos); si no, usa el más cercano para no
llevar una mano ausente (ceros) al pecho. Reinicia las compuertas al empezar y
al terminar: la plantilla arranca su reloj en 0 y antes el torso quedaba
rechazado como `stale_frame` tras el vivo o una plantilla previa. `fin` sale
al terminar los frames; el retorno a reposo sigue después.

## Calentamiento de la captura web

Los primeros resultados del worker llegan con 1–2.5 s de retraso (carga de
modelos y shaders). Esos frames se registran en la sesión y alimentan perfil
y calibración, pero no mueven el avatar: el calentamiento termina con 3
frames seguidos de latencia ≤ 200 ms o a los 3 s (equipo lento), y deja un
evento `capture_warmup` con los descartados. Después, ningún frame se
descarta por latencia.

## Pose medida del avatar

En web, una vez por frame de cámara el visor guarda los cuaterniones locales
aplicados a `UpperArm`, `LowerArm`, `Hand` (ambos lados) y `Head` tras
compuerta, filtros, zona muerta y transiciones, más el estado del avatar.
Viajan en el campo `avatar` del registro de sesión del frame siguiente
(desfase de un frame, irrelevante para jitter). Android no lo registra: su
sesión la escribe Dart y no ve los huesos del WebView.

## Manos

Los cuatro dedos largos siguen `Proximal → Intermediate → Distal`. El pulgar
del avatar presente usa `Metacarpal → Proximal → Distal`. La nomenclatura debe
detectarse desde `VRMHumanBoneName`, no suponerse.

Si una cadena de falanges es degenerada:

- no abrir/cerrar de golpe;
- conservar última rotación válida;
- bajar confianza;
- esperar una cadena geométricamente útil.

La ruta rápida usa `FingerRenderState` separado de `MotionFrameV2`: forma XYZ
queda sin segundo suavizado, ángulos MCP/PIP/DIP reciben un único filtro rápido
y cada entrada se identifica por timestamp para evitar colas viejas.

## Render y datos

El suavizado es visual: no debe contaminar el vector guardado si la captura
requiere datos canónicos. El avatar puede interpolar a 60 FPS entre estados de
tracking a 30 FPS.

La cara se suaviza por render con factor por tiempo
(`smoothingAlpha(dt, tau)`, `tau` tal que da 0.5 a 60 Hz): igual a 60, 144 o
30 Hz.
