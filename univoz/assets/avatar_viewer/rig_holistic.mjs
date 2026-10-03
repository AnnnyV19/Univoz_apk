// Captura unificada con MediaPipe HolisticLandmarker: un solo modelo para
// cuerpo, manos y cara (543 puntos), con manos ancladas a la pose y landmarks
// metricos tambien para las manos.
//
// holisticToTaskResults traduce su resultado al MISMO formato que hoy
// entregan PoseLandmarker + HandLandmarker por separado. Asi toda la cadena
// existente (asignacion por cadena de brazo, filtros, 152D, SignSpace) queda
// igual y solo cambia la fuente. Las etiquetas Left/Right de Holistic se
// pasan como pista; el lado fisico lo sigue decidiendo assignHandsByArmChain.

// Modelo oficial float16 (13.7 MB), empaquetado junto al visor para
// funcionar sin red. La URL oficial queda como respaldo.
export const HOLISTIC_MODEL_LOCAL = 'holistic_landmarker.task';
export const HOLISTIC_MODEL_URL = 'https://storage.googleapis.com/' +
  'mediapipe-models/holistic_landmarker/holistic_landmarker/float16/latest/' +
  'holistic_landmarker.task';

const first = (list) => (Array.isArray(list) && list.length ? list[0] : null);

export function holisticToTaskResults(result) {
  const pose = first(result?.poseLandmarks);
  const poseWorld = first(result?.poseWorldLandmarks);
  const poseResult = pose ? {landmarks: [pose],
    worldLandmarks: poseWorld ? [poseWorld] : []} : null;

  const landmarks = [], worldLandmarks = [], handednesses = [];
  for (const [label, image, world] of [
    ['Left', result?.leftHandLandmarks, result?.leftHandWorldLandmarks],
    ['Right', result?.rightHandLandmarks, result?.rightHandWorldLandmarks],
  ]) {
    const hand = first(image);
    if (!hand) continue;
    landmarks.push(hand);
    worldLandmarks.push(first(world));
    handednesses.push([{categoryName: label, score: 1, index: label === 'Left' ? 0 : 1}]);
  }

  const faceLandmarks = first(result?.faceLandmarks);
  const blend = first(result?.faceBlendshapes)?.categories ?? [];
  const face = faceLandmarks ? {
    landmarks: faceLandmarks,
    blendshapes: Object.fromEntries(blend.map((c) =>
      [c.categoryName, Number(c.score) || 0])),
  } : null;

  return {poseResult, handResult: {landmarks, worldLandmarks, handednesses}, face};
}
