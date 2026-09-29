"""Extrae landmarks (pose + manos) crudos de un video, frame por frame.

Usa los mismos dos modelos que el lado nativo (hand_landmarker.task,
pose_landmarker_lite.task) pero en RunningMode.VIDEO en vez de LIVE_STREAM:
aca no hay camara en vivo, así que se puede pedir el resultado de forma
sincronica, frame por frame, sin canales ni callbacks.

La salida (lista de (pose, pose_mundo, left, right) por frame) tiene EXACTAMENTE el
mismo formato que espera sign_norm.normalize_sequence -- es el mismo
"contrato" que ya usa el golden test entre Dart y Python.
"""

import cv2
import mediapipe as mp
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision


def _punto_pose(p):
    return [p.x, p.y, p.z, p.visibility]


def _punto_mano(p):
    return [p.x, p.y, p.z]


def _punto_pose_mundo(p):
    return [p.x, p.y, p.z]


def tapar(frame, mascara):
    """Rellena de blanco un rectangulo del frame (x0,y0,x1,y1 en fracciones).

    Para los videos de diccionario que traen un recuadro chico con un
    segundo plano de la misma persona: si no se tapa, el detector (que corre
    con num_hands=2) encuentra tambien la mano de ESE recuadro, y una mano
    que no es la de la sena entra a la muestra.

    Se TAPA, no se recorta: recortar cambiaria la relacion de aspecto, y
    como MediaPipe normaliza x por el ancho e y por el alto, eso estiraria
    la forma de la mano en un eje y no en el otro. La forma se guarda en
    coordenadas de imagen, asi que esa deformacion si cambiaria el vector.
    """
    alto, ancho = frame.shape[:2]
    x0, y0, x1, y1 = mascara
    frame[int(y0 * alto):int(y1 * alto), int(x0 * ancho):int(x1 * ancho)] = 255
    return frame


def asignar_manos(manos, pose, l_wrist=15, r_wrist=16):
    """Decide cual mano detectada es la izquierda y cual la derecha.

    Compara cada mano contra las munecas que devuelve el modelo de POSE, y
    se queda con el emparejamiento de menor distancia total. La etiqueta de
    MediaPipe ("Left"/"Right") NO se usa: su convencion supone una imagen
    espejada, asi que en un video grabado con camara trasera sale al reves,
    y no hay forma de saberlo mirando solo la mano.

    Esto es lo mismo que ya hace el lado nativo de la app
    (HandTrackCoordinator.kt), que trata la cadena del brazo como la
    autoridad y la etiqueta como mucho como evidencia secundaria. Mientras
    el Python use la etiqueta y la app use la anatomia, una misma sena
    ingerida por video y capturada en vivo puede quedar con las manos
    cruzadas entre si -- y el reconocimiento compara justamente una contra
    la otra.

    `manos` es una lista de listas de 21 puntos [x, y, z].
    Devuelve (izquierda, derecha), cualquiera de las dos puede ser None.
    """
    if not manos:
        return None, None
    if pose is None or len(pose) <= max(l_wrist, r_wrist):
        # Sin pose no hay con que comparar. Con una sola mano no se puede
        # inventar el lado, asi que se descarta antes que arriesgar una
        # muestra con la mano cambiada.
        return (None, None) if len(manos) == 1 else (manos[0], manos[1])

    mi, md = pose[l_wrist], pose[r_wrist]

    def dist(mano, muneca):
        p = mano[0]  # la muneca de la propia mano
        return (p[0] - muneca[0]) ** 2 + (p[1] - muneca[1]) ** 2

    if len(manos) == 1:
        m = manos[0]
        return (m, None) if dist(m, mi) <= dist(m, md) else (None, m)

    # Con dos manos se elige el emparejamiento completo mas barato, no la
    # mejor para cada una por separado: si las dos caen cerca de la misma
    # muneca, decidir de a una las asignaria al mismo lado.
    a, b = manos[0], manos[1]
    recto = dist(a, mi) + dist(b, md)
    cruzado = dist(b, mi) + dist(a, md)
    return (a, b) if recto <= cruzado else (b, a)


class ExtractorLandmarks:
    def __init__(
        self,
        pose_model_path,
        hand_model_path,
        min_pose_conf=0.5,
        min_hand_conf=0.5,
        min_tracking_conf=0.5,
    ):
        base = mp_python.BaseOptions
        self.pose = vision.PoseLandmarker.create_from_options(
            vision.PoseLandmarkerOptions(
                base_options=base(model_asset_path=pose_model_path),
                running_mode=vision.RunningMode.VIDEO,
                num_poses=1,
                min_pose_detection_confidence=min_pose_conf,
                min_pose_presence_confidence=min_pose_conf,
                min_tracking_confidence=min_tracking_conf,
            )
        )
        self.hands = vision.HandLandmarker.create_from_options(
            vision.HandLandmarkerOptions(
                base_options=base(model_asset_path=hand_model_path),
                running_mode=vision.RunningMode.VIDEO,
                num_hands=2,
                min_hand_detection_confidence=min_hand_conf,
                min_hand_presence_confidence=min_hand_conf,
                min_tracking_confidence=min_tracking_conf,
            )
        )
        # Los modelos en RunningMode.VIDEO exigen timestamps estrictamente
        # crecientes durante TODA la vida del objeto, no por video. Para
        # poder reusar un mismo ExtractorLandmarks en varios videos seguidos
        # (tools/ingest_carpeta.py reusa uno solo para toda la carpeta, para
        # no recargar los modelos en cada archivo, que es lo que tarda),
        # cada llamada a extraer() arranca su reloj justo despues de donde
        # termino el video anterior, en vez de repetir desde 0.
        self._proximo_t_ms = 0

    def cerrar(self):
        self.pose.close()
        self.hands.close()

    def extraer(self, video_path, mascara=None):
        """Devuelve (raw_frames, fps, n_frames).

        raw_frames: lista de (pose, pose_mundo, left, right) por cada frame leido del
        video, en el mismo formato que sign_norm.normalize_sequence espera
        (pose: 33 x [x,y,z,vis] o None; left/right: 21 x [x,y,z] o None).
        """
        cap = cv2.VideoCapture(video_path)
        if not cap.isOpened():
            raise RuntimeError(f"no se pudo abrir el video: {video_path}")

        # Auto-rota segun la metadata de orientacion del archivo si el
        # build de OpenCV lo soporta (evita analizar un video "de costado"
        # cuando el telefono grabo en vertical pero guardo el pixel en
        # horizontal con un flag de rotacion aparte).
        try:
            cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
        except Exception:
            pass

        fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
        t_base = self._proximo_t_ms

        raw_frames = []
        idx = 0
        t_ms = t_base
        while True:
            ok, frame_bgr = cap.read()
            if not ok:
                break

            if mascara:
                frame_bgr = tapar(frame_bgr.copy(), mascara)

            rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
            mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
            t_ms = t_base + int(idx * 1000 / fps)

            pose_res = self.pose.detect_for_video(mp_image, t_ms)
            hand_res = self.hands.detect_for_video(mp_image, t_ms)

            pose = None
            if pose_res.pose_landmarks:
                pose = [_punto_pose(p) for p in pose_res.pose_landmarks[0]]

            pose_mundo = None
            if pose_res.pose_world_landmarks:
                pose_mundo = [_punto_pose_mundo(p)
                              for p in pose_res.pose_world_landmarks[0]]

            manos = [[_punto_mano(p) for p in lm]
                     for lm in hand_res.hand_landmarks]
            left, right = asignar_manos(manos, pose)

            raw_frames.append((pose, pose_mundo, left, right))
            idx += 1

        cap.release()
        # Deja el reloj listo para el proximo video de esta misma instancia,
        # con 1 segundo de margen para no repetir el ultimo timestamp usado.
        self._proximo_t_ms = t_ms + 1000
        return raw_frames, fps, idx
