# Reglas de R8 para el release de Univoz (ver docs/RELEASE.md).

# MediaPipe tasks (tasks-vision / tasks-core): carga clases por JNI y
# reflexión desde código nativo.
-keep class com.google.mediapipe.** { *; }
-dontwarn com.google.mediapipe.**

# Protobuf (protobuf-java 4.x): los mensajes de MediaPipe usan reflexión
# sobre sus campos.
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.protobuf.**

# Motor de captura propio (LandmarkPlugin y compañía, paquete com.univoz.senas)
# y la MainActivity que lo registra.
-keep class com.univoz.senas.** { *; }
-keep class com.example.univoz.** { *; }

# Anotaciones de tiempo de compilación que traen MediaPipe y sus dependencias
# y que no existen en Android.
-dontwarn javax.lang.model.**
-dontwarn javax.annotation.**
-dontwarn com.google.auto.value.**
-dontwarn autovalue.shaded.**
-dontwarn com.google.errorprone.annotations.**
-dontwarn org.checkerframework.**
