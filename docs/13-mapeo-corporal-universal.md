# Mapeo corporal universal — cualquier cuerpo → avatar

## Objetivo

Que el avatar VRM:

1. **Copie en vivo** a cualquier usuario: niño o adulto, brazos largos o cortos,
   sentado, en silla de ruedas, con encuadre de medio cuerpo, con amputación o
   movilidad reducida.
2. **Reproduzca señas** grabadas por otra persona (biblioteca, texto/voz →
   seña) sin heredar las proporciones de quien las grabó.

Abreviaturas como en [11](11-auditoria-sistema-unico.md): `H` = visor,
`K` = Kotlin de `senas_core`.

## Estado actual

- El avatar consume el mismo vector 152D del reconocimiento (`H:5494`
  `aplicarFrame`). El cuerpo llega en "anchos de hombro" del usuario.
- `resolverBrazo` (`H:3439`) calcula la muñeca objetivo como
  `(muñeca − hombro)` × ancho de hombros del avatar × ganancia, y resuelve IK de
  dos huesos con las longitudes del avatar. Si los brazos del usuario son
  proporcionalmente más largos o cortos, la mano cae en otro lugar o se recorta
  contra el alcance.
- Del usuario solo se mide el pulgar (`H:4135`, `univoz.thumbCalibration.v2`).
  `RigCalibration` (`senas_core/lib/motion_contract.dart:182`) son ajustes del
  rig, no antropometría.
- `medirRig` (`H:3148`) mide el avatar en T-pose (brazo, antebrazo, reposo).
- MediaPipe: pose `lite` (`K/LandmarkEngine.kt:143`) con world landmarks
  (`K/LandmarkEngine.kt:276`); manos con 2 detecciones y umbral 0.4
  (`K/LandmarkEngine.kt:132-133`) pero solo en coordenadas de imagen; sin cara.
- Si faltan hombros se descarta el frame; si falta el codo, el brazo vuelve a
  reposo; una mano ausente se trata como perdida.

## Idea central

Separar **qué seña es** de **cómo es el cuerpo**. Hoy 152D mezcla ambas cosas
(conserva las proporciones del usuario). Se añade una representación
intermedia, sin tocar 152D:

```
MediaPipe (Nivel 1, envuelto)         Perfil del usuario              Perfil del avatar
pose + manos world + cara       →     BodyProfileV1 + CapabilityMask   AvatarRigProfile
            │                                  │                              │
            ▼                                  ▼                              ▼
  Landmark Hospital ──► SignSpaceFrame (independiente del cuerpo) ──► Retargeter ──► VRM
                              │
                              ├──► MotionFrameV2 152D (reconocimiento, intacto)
                              └──► Biblioteca de señas
            cara ──► FaceFrameV1 (canal aparte) ──► cabeza, cejas, boca del avatar
```

## `SignSpaceFrame` (contrato nuevo, versionado)

| Bloque | Contenido | Por qué |
|---|---|---|
| Direcciones | Vector unitario por segmento: hombro→codo, codo→muñeca, huesos de dedos | Invariante a longitud: se aplica a cualquier esqueleto sin deformar |
| Ubicación | Posición de cada muñeca relativa a anclas (mentón, nariz, frente, pecho, hombro contrario, cadera), normalizada por medidas del propio usuario | En lengua de señas el lugar es fonológico: el avatar debe tocar **su** mentón |
| Contactos | Flags mano–cara, mano–mano, mano–pecho con umbral relativo al tamaño de la mano | Preserva toques aunque cambien proporciones |
| Orientación | Marco de palma (`palmFrameV2`) | Un solo marco para render y reconocimiento |
| Máscara y confianza | Por articulación, fuera de los valores | Nunca ceros semánticos |

Implementación dual Dart/Python con golden tests, como `sign_norm`.

## Perfiles

**`BodyProfileV1`** (Fast User Capture, 3 poses guiadas de ~5 s: neutra, brazos
al frente, manos abiertas/cerradas). Mediana de ancho de hombros, brazo,
antebrazo, mano, huesos de dedos, alturas hombro↔mentón/nariz, alcance. Reusa
la lógica de calibración del pulgar (muestras estables, umbral de calidad).
Local, versionado, borrable, con consentimiento; sin video.

**`HandCapabilityModel` + `CapabilityMask`**. Segmentos ausentes (dedo, mano,
antebrazo) y rango de movimiento observado. Vive fuera de 152D y de
`SignSpaceFrame`.

**`AvatarRigProfile`**. Extiende `medirRig` con anclas del VRM (cabeza,
mentón, pecho, caderas) y longitudes de dedos.

## Retargeter

1. Brazo: dirección de cada segmento del usuario × longitud del segmento del
   avatar.
2. Cerca de un contacto, la muñeca se resuelve hacia el ancla correspondiente
   del avatar (blend dirección ↔ ancla según distancia), con la IK de dos huesos
   existente.
3. Dedos por ángulos con límites anatómicos.
4. `jointLimits` reales en hombro, codo, muñeca y torso.
5. Capacidad: en espejo, el usuario elige representación fiel (segmento
   ausente) o completada; en reproducción de biblioteca, el avatar ejecuta la
   seña completa.

## Casos difíciles

| Caso | Tratamiento |
|---|---|
| Niño / proporciones extremas | Direcciones + anclas: la seña cae en el mismo lugar del avatar |
| Sentado / silla de ruedas | Modo tren superior: raíz en hombros, caderas solo con visibilidad |
| Encuadre parcial | Reconstrucción con longitudes del perfil, no descarte |
| Amputación / dedo ausente | `CapabilityMask`; DTW enmascarado en reconocimiento |
| Movilidad reducida | Rango observado en el perfil; reconocimiento tolerante por máscara |
| Zurdo | Mano dominante en vivo, espejo en reconocimiento y avatar |
| Rasgos no manuales | `FaceFrameV1`: giro de cabeza, cejas, boca, mirada |

## Captura y robustez (estado)

- **Holistic único** (web y Android): cuerpo, manos (con métricas) y cara en
  una pasada; pose y manos del mismo frame. Respaldo automático a Pose + Hand.
- **Compuerta de manos** antes de asignar lado: duplicados, mano lejos de
  las muñecas visibles, tamaño imposible y confirmación de manos sin ancla.
  La muñeca que la pose no ve pesa menos al decidir el lado.
- **Codo oculto** reconstruido con el perfil (`reconstructed`).
- **Cara**: giro de cabeza y expresiones geométricas (blendshapes no corren
  en GPU WebGL).
- **Sesión automática** con consentimiento: mide el cuerpo y graba todo
  para analizar fallos; **Audit Sentinel** offline marca longitudes óseas
  fuera del perfil y teletransportes de muñeca.

## Cómo probarlo

```bash
./scripts/univoz.sh web
# abrir http://127.0.0.1:8080/assets/avatar_viewer/index.html?standalone=1&retarget=anchors
```

En el panel: `Iniciar cámara`, marcar *Adaptar a mi cuerpo (anclas)* y,
opcional, `Medir mi cuerpo`. Comparar con la casilla desmarcada (`legacy`)
tocándose mentón, nariz y pecho.

## Verificación

- Golden Dart == Python para `SignSpaceFrame`.
- Retarget sintético: mismo clip con esqueleto escalado 0.6× y 1.4× ⇒ la mano
  llega a la misma ancla del avatar con error < 5 % del ancho de hombros.
- Fixtures de amputación y dedo ausente ⇒ máscara correcta y 152D sin ceros.
- Sesiones físicas con la matriz de sujetos de Fase 0, comparadas contra el
  baseline.
