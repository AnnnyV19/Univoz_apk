import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('visor expone contrato RigBody V2 sin cola de frames vivos', () {
    final html = File('assets/avatar_viewer/index.html').readAsStringSync();

    expect(html, contains('window.configurarRig'));
    expect(html, contains('window.aplicarFrameVivo'));
    expect(html, contains('RigBodyEngine'));
    expect(html, contains('aplicarTorso'));
    expect(html, contains('getNormalizedBoneNode'));
    expect(html, contains('anchoHombrosAvatar'));
    expect(html, contains('radioObjetivo'));
    expect(html, contains('elbowTarget'));
    expect(html, contains('timestampMs'));
    expect(html, contains('quality'));
    expect(html, contains('kFrameDim = 152'));
    expect(html, contains('frameVivo'));
    expect(html, contains('createRigSafetyGate'));
    expect(html, contains('aplicarRotacionSegura'));
    expect(html, contains('fingerRenderState'));
    expect(html, contains('fingerLag'));
    expect(html, contains('rigAudit'));
    expect(html, contains('deadbandHeld'));
    expect(html, contains('posarReposoBrazo'));
  });

  test('visor cablea SignSpaceFrame y retarget por anclas tras flag', () {
    final html = File('assets/avatar_viewer/index.html').readAsStringSync();

    // Modulos inline generados desde los .mjs.
    expect(html, contains('// ---- inicio rig_sign_space.mjs'));
    expect(html, contains('// ---- inicio rig_retarget.mjs'));
    // Web calcula SignSpace; Android lo recibe validado por el puente.
    expect(html, contains('signSpaceFrame(pose, poseMundo), timestampMs)'));
    expect(html,
        contains('parseSignSpaceFrame(sourceMeta?.sign_space), frameVivoTimestampMs)'));
    expect(html, contains('filtroSignSpace.reset()'));
    expect(html, contains('mirrorSignSpaceFrame(signSpaceVivo)'));
    expect(html, contains(': signSpaceVivo,'));
    // resolverBrazo cae a legacy si no hay retarget.
    expect(html, contains('deltaMunecaRetarget(lado, meta.signSpace) ??'));
    // Apagado por defecto hasta validar en camara fisica.
    expect(html, contains("let retargetMode = 'legacy';"));
    expect(html, contains('window.configurarRetarget'));
  });

  test('biblioteca: grabacion y reproduccion llevan pista SignSpace', () {
    final html = File('assets/avatar_viewer/index.html').readAsStringSync();
    expect(html, contains('webGrabacionSignSpace.push(signSpaceVivo)'));
    expect(html, contains('sign_space: webUltimaSignSpace'));
    expect(html, contains('signSpace: colaSignSpace?.[frameActual] ?? null'));
    expect(html, contains("typeof seqJson === 'string'"));
    final bridge = File('lib/avatar_bridge.dart').readAsStringSync();
    expect(bridge, contains("'signSpace': pista"));
  });

  test('perfil corporal: consentimiento, local y borrable', () {
    final html = File('assets/avatar_viewer/index.html').readAsStringSync();
    expect(html, contains('window.iniciarCapturaPerfil'));
    expect(html, contains('window.borrarPerfilCorporal'));
    expect(html, contains('localStorage.removeItem(BODY_PROFILE_STORAGE_KEY)'));
    expect(html, contains('window.confirm('));
    expect(html, contains('iniciarCapturaPerfil({consent: true})'));
    expect(html, contains('alimentarCapturaPerfil(pose, poseMundo)'));
  });

  test('vista espejo solo para el frame en vivo, interlocutor por defecto', () {
    final html = File('assets/avatar_viewer/index.html').readAsStringSync();
    expect(html, contains("let vistaAvatar = 'interlocutor';"));
    expect(html, contains('window.configurarVista'));
    expect(html, contains('espejo ? mirrorMotionFrame(frameVivo) : frameVivo'));
    // la reproduccion de biblioteca no se espeja
    expect(html, contains('RigBodyEngine.aplicarFrame(colaFrames[frameActual], {'));
  });

  test('captura unificada Holistic y cara al avatar tras flag', () {
    final html = File('assets/avatar_viewer/index.html').readAsStringSync();
    expect(html, contains("let capturaModo = 'separado';"));
    expect(html, contains('vision.HolisticLandmarker.createFromOptions'));
    expect(html, contains('holisticToTaskResults('));
    // blendshapes fallan en GPU WebGL: expresiones por geometria
    expect(html, contains('outputFaceBlendshapes: false'));
    expect(html, contains('expressionsFromFaceLandmarks(cara.landmarks'));
    expect(html, contains('caerHolisticACpu(error)'));
    expect(html, contains('aplicarCara(caraVivo, espejo'));
    expect(html, contains("'Neck', 'Head']"));
    // el parpadeo generico cede ante la cara real
    expect(html, contains('performance.now() - caraAplicadaAt < 500'));
  });
}
