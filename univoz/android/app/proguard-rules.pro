# Reglas de R8 para el release de Univoz (ver docs/RELEASE.md).

# MediaPipe tasks (tasks-vision / tasks-core): carga clases por JNI y
# reflexión desde código nativo.
-keep class com.google.mediapipe.** { *; }
-dontwarn com.google.mediapipe.**

# Flogger (logger de MediaPipe): busca a quien lo llama recorriendo la pila
# por nombre de clase. Con R8 renombrado/inlined, Graph.<clinit> fallaba con
# "no caller found on the stack" y la app se cerraba al abrir la camara.
-keep class com.google.common.flogger.** { *; }
-dontwarn com.google.common.flogger.**

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
