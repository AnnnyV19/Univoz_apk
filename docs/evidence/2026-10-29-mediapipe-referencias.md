# MediaPipe en Univoz: qué trae realmente el bundle (REA, 2026-10-29)

Herramienta: REA 6.5.0 (`rea inspect-artifact`) sobre `app-arm64-v8a-release.apk`; `strings` sobre su `libmediapipe_tasks_jni.so`; `zipfile` sobre los `.task` (REA no abre un `.task`/zip genérico: `unsupported binary format`). No se analizó ninguna app de terceros.

## Observaciones
- El APK empaqueta `lib/arm64-v8a/libmediapipe_tasks_jni.so` (11 MB) y `assets/{holistic_landmarker,hand_landmarker,pose_landmarker_lite}.task`.
- `holistic_landmarker.task` (13.7 MB) contiene: `hand_landmarks_detector`, `hand_roi_refinement`, `face_detector`, `face_landmarks_detector`, `face_blendshapes`, `pose_detector`, `pose_landmarks_detector`. **No contiene `hand_detector` (detector de palma).**
- `hand_landmarker.task` (7.8 MB) sí: `hand_detector.tflite` (2.3 MB) + `hand_landmarks_detector.tflite`.
- La lib nativa trae `HolisticLandmarkerGraph`, `HandDetectorGraph`, `HandRoiRefinementGraph`, y símbolos `_HAND_ROI_FROM_POSE`, `_HAND_ROI_FROM_RECROP`, `hand_detections_from_pose_to_rects_calculator.cc`, `roi_tracking_calculator.cc`, `holistic_pose_tracking.cc`.

## Inferencias (a confirmar en el teléfono)
1. En Holistic las manos nacen del **ROI derivado de la pose** (muñeca/dedos de la pose → rectángulo → refinamiento → landmarks de mano). Sin una pose con la muñeca bien ubicada, no hay mano; no hay un detector de palma que la rescate. Cuadra con: muñecas con visibilidad 0.2–0.7, brazos fuera de cuadro, `bone_length_*` anómalo en 44 % de frames y solo 5–10 % de cobertura de mano.
2. `HandLandmarker` (camino `separado`, ya existe el toggle `forzarSeparado`) usa su propio detector de palma sobre el frame completo: no depende de la pose. Es la palanca nº 1 de la Fase 2.
3. Holistic no expone `numHands` ni umbrales de detección de mano; el único umbral de mano es `minHandLandmarksConfidence` (0.4 hoy).

## Desconocidos
- Tamaño de entrada exacto de cada `.tflite` y la expansión del ROI (no se parsearon los modelos).
- Cuánto del 77 % sin mano se debe al ROI de pose y cuánto a resolución 360×480, luz o encuadre: lo decide el A/B.
