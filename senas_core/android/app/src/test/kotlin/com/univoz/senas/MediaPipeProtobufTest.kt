package com.univoz.senas

import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.holisticlandmarker.HolisticLandmarker
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * MediaPipe tasks 1.0.0 arma sus opciones con com.google.protobuf.Any y
 * llama Any.Builder.build() con la firma de protobuf-java (completo). Con
 * protobuf-javalite esa firma no existe: NoSuchMethodError al crear
 * Holistic y la app se cierra al abrir la camara (Galaxy S22+, 2026-10-19).
 */
class MediaPipeProtobufTest {
    private fun base() = BaseOptions.builder().setModelAssetPath("modelo.task").build()

    @Test fun opcionesDeHolisticSeConviertenAProto() {
        val any = HolisticLandmarker.HolisticLandmarkerOptions.builder()
            .setBaseOptions(base())
            .setRunningMode(RunningMode.IMAGE)
            .build()
            .convertToAnyProto()
        assertTrue(any.typeUrl, any.typeUrl.contains("HolisticLandmarkerGraphOptions"))
    }
}
