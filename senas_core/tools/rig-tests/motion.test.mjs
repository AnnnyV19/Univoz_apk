import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';
import * as THREE from 'three';
import {
  createThumbCalibration,
  measureThumbPose,
  solveThumbPose,
} from '../../assets/avatar_viewer/rig_math.mjs';
import { createRigSafetyGate } from '../../assets/avatar_viewer/rig_safety.mjs';
import { signSpaceFrame } from '../../assets/avatar_viewer/rig_sign_space.mjs';
import {
  createAvatarRigProfile,
  retargetArm,
} from '../../assets/avatar_viewer/rig_retarget.mjs';
import {
  assignHandsByArmChain,
  resolveAnatomicalHandSide,
} from '../../assets/avatar_viewer/rig_tracking.mjs';

// Execute production functions with real Three.js math, without camera/DOM.
const html = readFileSync(new URL('../../assets/avatar_viewer/index.html', import.meta.url), 'utf8');
function source(name) {
  const start = html.indexOf(`    function ${name}(`);
  assert.ok(start >= 0, `Missing production function ${name}`);
  return html.slice(start, html.indexOf('\n    }', start) + 6);
}
function sourceBlock(name) {
  const start = html.indexOf(`    function ${name}(`);
  assert.ok(start >= 0, `Missing production function ${name}`);
  const open = html.indexOf('{', start);
  let depth = 0;
  for (let index = open; index < html.length; index++) {
    if (html[index] === '{') depth++;
    if (html[index] === '}') depth--;
    if (depth === 0) return html.slice(start, index + 1);
  }
  assert.fail(`Unclosed production function ${name}`);
}
function runtime(names, extra = {}) {
  const ctx = vm.createContext({
    THREE, Math, Number, Array, kMadMinSigmaRig: 0.005, ...extra,
  });
  vm.runInContext(names.map(source).join('\n'), ctx);
  return ctx;
}
const vector = (...p) => new THREE.Vector3(...p);
const base = { pDer: vector(1,0,0), pArr: vector(0,1,0), pFre: vector(0,0,1) };
const mathRuntime = () => runtime(['vectorBaseAvatar', 'aBaseAvatar', 'vectorManoAAvatar'], {
  cal: { invertZ: false }, avDerecha: vector(-1,0,0),
  avArriba: vector(0,1,0), avFrente: vector(0,0,1),
});
const calStart = html.indexOf('const cal =');
const calBlock = html.slice(calStart, html.indexOf('\n    };', calStart));
const productionFingerSigns = {
  left: Number(calBlock.match(/left:\s*\{[^\n]*dedos:\s*(-?\d+)/)[1]),
  right: Number(calBlock.match(/right:\s*\{[^\n]*dedos:\s*(-?\d+)/)[1]),
};
const coord = (x,y,z=0) => ({ x,y,z,visibility:1 });
function hand(x,y) { return Array.from({length:21}, () => coord(x,y)); }
function pose() {
  const p = Array.from({length:33}, () => coord(0,0));
  p[11]=coord(.7,.4); p[12]=coord(.3,.4);
  p[15]=coord(.75,.2); p[16]=coord(.25,.3);
  return p;
}

test('live hand side stays pending until pose arm chain is ready', () => {
  assert.deepEqual(resolveAnatomicalHandSide({
    mode: 'fallback', sideByIndex: ['right'],
  }, 0), {side: null, sideLocked: false, sideAmbiguous: true});
  assert.deepEqual(resolveAnatomicalHandSide({
    mode: 'pose_arm_chain', sideByIndex: ['left'],
  }, 0), {side: 'left', sideLocked: true, sideAmbiguous: false});
});
test('two hands use one-to-one pose matching when one crosses center', () => {
  const p=pose(); p[15]=coord(.35,.2); p[16]=coord(.65,.3);
  const hCenter=hand(.50,.25), hRight=hand(.65,.3);
  const result=assignHandsByArmChain([
    {landmarks:hRight, side:''}, {landmarks:hCenter, side:''},
  ], {
    leftShoulder: coord(.70,.4), leftElbow: coord(.45,.3), leftWrist: p[15],
    rightShoulder: coord(.30,.4), rightElbow: coord(.55,.3), rightWrist: p[16],
    shoulderWidth: .4,
  });
  assert.deepEqual(result.sideByIndex, ['right', 'left']);
});
test('ambiguous arm-chain assignment never guesses a side', () => {
  const result = assignHandsByArmChain([
    {landmarks:hand(.49,.25), side:''},
    {landmarks:hand(.51,.25), side:''},
  ], {
    leftShoulder: coord(.40,.35), leftElbow: coord(.46,.45), leftWrist: coord(.50,.25),
    rightShoulder: coord(.60,.35), rightElbow: coord(.54,.45), rightWrist: coord(.50,.25),
    shoulderWidth: .2,
  });
  assert.deepEqual(result.sideByIndex, [null, null]);
  assert.equal(result.mode, 'ambiguous');
});
test('normalized upward fingers remain upward in avatar', () => {
  // For a front-facing person cosT=-1; image dy<0 becomes shape y>0.
  const out=mathRuntime().vectorManoAAvatar([0,1,0],base);
  assert.ok(out.y > .999, `fingers point down: ${out.y}`);
});
test('hand depth toward camera points forward on avatar', () => {
  const out=mathRuntime().vectorManoAAvatar([0,0,-1],base);
  assert.ok(out.z > .999, `palm depth reversed: ${out.z}`);
});

test('marcoMano rejects invalid CMC without throwing', () => {
  const ctx = vm.createContext({THREE, Math, Number});
  vm.runInContext(sourceBlock('marcoMano'), ctx);
  const x = new THREE.Vector3(0, 1, 0);
  const y = new THREE.Vector3(1, 0, 0);
  assert.doesNotThrow(() => ctx.marcoMano(x, y, [0, 0, 1]));
  assert.equal(ctx.marcoMano(x, y, [0, 0, 1]), null);
  assert.equal(ctx.marcoMano(x, y, new THREE.Vector3(0, 0, 0)), null);
  assert.equal(ctx.marcoMano(x, y, new THREE.Vector3(NaN, 0, 1)), null);
});

test('orientarMuneca no voltea la palma segun el CMC', () => {
  // Auditoria 2026-10-20: con landmarks 3D el vector indice->menique ya fija
  // de que lado esta el pulgar; voltear segun el CMC (casi sobre el eje
  // muneca->nudillo medio) giraba la palma 180 grados en ~20% de las señas.
  const start = html.indexOf('    function orientarMuneca(');
  const end = html.indexOf('    function ponerMunecaReposo(', start);
  assert.ok(start >= 0 && end > start, 'Missing wrist orientation block');
  const block = html.slice(start, end);
  assert.match(block, /const objetivo = marcoMano\(dedos, ancho\);/);
  assert.doesNotMatch(block, /marcoMano\(dedos, ancho, cmc\)/);
  assert.doesNotMatch(block, /marcoMano\(dedos, ancho, puntos\[0\]\)/);
});

function thumbRuntime(side) {
  const hand = new THREE.Object3D();
  const metacarpal = new THREE.Object3D();
  const proximal = new THREE.Object3D();
  const distal = new THREE.Object3D();
  const sign = side === 'left' ? -1 : 1;
  // Bind directions from UNIVOZ's VRM thumb chain.
  metacarpal.position.set(sign * .003, -.008, -.013);
  proximal.position.set(sign * .029, -.002, -.025);
  distal.position.set(sign * .019, -.001, -.015);
  hand.add(metacarpal); metacarpal.add(proximal); proximal.add(distal);

  const names = side === 'left'
    ? { metacarpal:'leftThumbMetacarpal', proximal:'leftThumbProximal', distal:'leftThumbDistal' }
    : { metacarpal:'rightThumbMetacarpal', proximal:'rightThumbProximal', distal:'rightThumbDistal' };
  const map = {
    [names.metacarpal]: metacarpal,
    [names.proximal]: proximal,
    [names.distal]: distal,
  };
  const ctx = vm.createContext({
    THREE, Math, Number, Array,
    VRMHumanBoneName: {
      LeftThumbMetacarpal:'leftThumbMetacarpal', LeftThumbProximal:'leftThumbProximal', LeftThumbDistal:'leftThumbDistal',
      RightThumbMetacarpal:'rightThumbMetacarpal', RightThumbProximal:'rightThumbProximal', RightThumbDistal:'rightThumbDistal',
    },
    bone: name => map[name] ?? null,
    kFasesGenericas: ['Proximal', 'Intermediate', 'Distal'],
    kFasesPulgar: ['Metacarpal', 'Proximal', 'Distal'],
    cal: {
      fingerSensitivity: 1,
      thumbCalibration: {
        left: createThumbCalibration(
          measureThumbPose(openThumbShape('left')),
          measureThumbPose(bentThumbShape('left')),
          1,
        ),
        right: createThumbCalibration(
          measureThumbPose(openThumbShape('right')),
          measureThumbPose(bentThumbShape('right')),
          1,
        ),
      },
      left: { dedos: productionFingerSigns.left },
      right: { dedos: productionFingerSigns.right },
    },
    thumbRigMap: {
      left: {
        Metacarpal: {axis:'x', sign:1},
        Proximal: {axis:'y', sign:-1},
        Distal: {axis:'z', sign:1},
      },
      right: {
        Metacarpal: {axis:'x', sign:-1},
        Proximal: {axis:'y', sign:1},
        Distal: {axis:'z', sign:-1},
      },
    },
    rigThumbState: {left:null, right:null},
    thumbNeutralRig: {left:null, right:null},
    measureThumbPose,
    solveThumbPose,
  });
  vm.runInContext([
    ...['_largo','_norm','_pto','_resta','_angulo','moverMano'].map(source),
  ].join('\n'), ctx);
  return { ctx, hand, metacarpal, proximal, distal };
}

function bentThumbShape(side) {
  const s = side === 'left' ? -1 : 1;
  const points = Array.from({length:20}, () => [0,0,0]);
  // CMC, MCP, IP and tip. Flexion points toward avatar-down.
  points[0] = [s * .10, 0, 0];
  points[1] = [s * .18, -.05, 0];
  points[2] = [s * .24, -.11, 0];
  points[3] = [s * .28, -.14, 0];
  points[8] = [0, -.20, 0];
  return points;
}

function openThumbShape(side) {
  const s = side === 'left' ? -1 : 1;
  const points = Array.from({length:20}, () => [0,0,0]);
  points[0] = [s * .10, 0, 0];
  points[1] = [s * .18, .02, 0];
  points[2] = [s * .26, .03, 0];
  points[3] = [s * .34, .04, 0];
  points[8] = [0, -.20, 0];
  return points;
}

for (const side of ['left', 'right']) {
  test(`${side} thumb applies independent calibrated bone axes`, () => {
    const {ctx, hand, metacarpal, proximal, distal} = thumbRuntime(side);
    ctx.moverMano(side, true, openThumbShape(side));
    const points = bentThumbShape(side);
    ctx.moverMano(side, true, points);
    hand.updateMatrixWorld(true);
    const s = side === 'left' ? 1 : -1;
    assert.ok(metacarpal.rotation.x * s > .1, `${side} CMC axis/sign ignored`);
    assert.ok(proximal.rotation.y * -s > .1, `${side} MCP axis/sign ignored`);
    assert.ok(distal.rotation.z * s > .1, `${side} IP axis/sign ignored`);
    assert.equal(metacarpal.rotation.z, 0);
    assert.equal(proximal.rotation.z, 0);
  });
}

function handLossRuntime(resetHandOnLoss = true) {
  const calls = [];
  const ctx = runtime(['actualizarEstadoPerdidaMano'], {
    cal: {resetHandOnLoss},
    kHandLossGraceMs: 250,
    estadoPerdidaMano: {
      left: {desde: 0, enReposo: false},
      right: {desde: 0, enReposo: false},
    },
    rigThumbState: {left: {}, right: {}},
    thumbNeutralRig: {left: {}, right: {}},
    ponerManoReposo: lado => calls.push(`mano:${lado}`),
    ponerMunecaReposo: lado => calls.push(`muneca:${lado}`),
  });
  return {ctx, calls};
}

test('hand loss waits grace, returns to rest and recalibrates on reappearance', () => {
  const {ctx, calls} = handLossRuntime();
  assert.equal(ctx.actualizarEstadoPerdidaMano('left', false, 100), false);
  assert.deepEqual(calls, []);
  assert.equal(ctx.actualizarEstadoPerdidaMano('left', false, 349), false);
  assert.deepEqual(calls, []);
  assert.equal(ctx.actualizarEstadoPerdidaMano('left', false, 350), false);
  assert.deepEqual(calls, ['mano:left', 'muneca:left']);
  assert.equal(ctx.estadoPerdidaMano.left.enReposo, true);
  assert.equal(ctx.actualizarEstadoPerdidaMano('left', true, 383), true);
  assert.equal(ctx.estadoPerdidaMano.left.enReposo, false);
  assert.equal(ctx.rigThumbState.left, null);
});

test('hand loss option disabled preserves last valid hand pose', () => {
  const {ctx, calls} = handLossRuntime(false);
  ctx.actualizarEstadoPerdidaMano('right', false, 100);
  ctx.actualizarEstadoPerdidaMano('right', false, 1000);
  assert.deepEqual(calls, []);
  assert.equal(ctx.estadoPerdidaMano.right.enReposo, false);
});

test('web pipeline wires adaptive calibration and pose stride without changing vector contract', () => {
  assert.match(html, /createAdaptiveMotionCalibrator/);
  assert.match(html, /createAdaptivePoseScheduler/);
  assert.match(html, /adaptivePoseScheduler\.shouldRun/);
  assert.match(html, /adaptiveMotionCalibrator\.update/);
  assert.match(html, /leftSurface/);
  assert.match(html, /kFrameDim = 152/);
  assert.match(html, /function normalizarFrameWeb\(pose, poseMundo, left, right,\s+renderWrists/);
});


test('overlay rejects non-finite and out-of-frame landmarks', () => {
  const c = runtime(['webCoord','webFinito','puntoEnCuadroWeb']);
  assert.equal(c.puntoEnCuadroWeb({x:.5,y:.5,z:0}), true);
  assert.equal(c.puntoEnCuadroWeb({x:1.01,y:.5,z:0}), false);
  assert.equal(c.puntoEnCuadroWeb({x:.5,y:-.01,z:0}), false);
  assert.equal(c.puntoEnCuadroWeb({x:NaN,y:.5,z:0}), false);
});



test('production rotation writer never applies invalid transform', () => {
  const gate = createRigSafetyGate();
  const h = new THREE.Object3D();
  const c = runtime(['metaRigFrame', 'aplicarRotacionSegura'], {
    safetyGateFor: () => gate,
    reportSafetyAnomaly: () => {},
    reportSafetyAdjustments: () => {},
    performance: {now: () => 1000},
  });
  c.aplicarRotacionSegura(h, 'left:Index:Proximal', [0.2, 0, 0], {
    frameId: 1, timestampMs: 1000,
  });
  const before = h.rotation.x;
  const result = c.aplicarRotacionSegura(h, 'left:Index:Proximal', [NaN, 0, 0], {
    frameId: 2, timestampMs: 1033,
  });
  assert.equal(result.accepted, false);
  assert.equal(result.code, 'non_finite_transform');
  assert.equal(h.rotation.x, before);
});




function fingerRuntime(side) {
  const hand = new THREE.Object3D();
  const proximal = new THREE.Object3D();
  const intermediate = new THREE.Object3D();
  const distal = new THREE.Object3D();
  const sign = side === 'left' ? -1 : 1;
  intermediate.position.x = sign * 0.028;
  distal.position.x = sign * 0.017;
  hand.add(proximal); proximal.add(intermediate); intermediate.add(distal);

  const names = side === 'left'
    ? { proximal:'leftIndexProximal', intermediate:'leftIndexIntermediate', distal:'leftIndexDistal' }
    : { proximal:'rightIndexProximal', intermediate:'rightIndexIntermediate', distal:'rightIndexDistal' };
  const map = {
    [names.proximal]: proximal,
    [names.intermediate]: intermediate,
    [names.distal]: distal,
  };
  const ctx = vm.createContext({
    THREE, Math, Number, Array,
    VRMHumanBoneName: {
      LeftIndexProximal:'leftIndexProximal', LeftIndexIntermediate:'leftIndexIntermediate', LeftIndexDistal:'leftIndexDistal',
      RightIndexProximal:'rightIndexProximal', RightIndexIntermediate:'rightIndexIntermediate', RightIndexDistal:'rightIndexDistal',
      LeftThumbMetacarpal: null,
    },
    bone: name => map[name] ?? null,
    cal: { fingerSensitivity: 1, left: { dedos:productionFingerSigns.left }, right: { dedos:productionFingerSigns.right } },
  });
  vm.runInContext([
    'const kFasesGenericas=["Proximal","Intermediate","Distal"];',
    'const kFasesPulgar=kFasesGenericas;',
    ...['_largo','_norm','_pto','_resta','_angulo','moverMano'].map(source),
  ].join('\n'), ctx);
  return { ctx, hand, intermediate, distal };
}

function bentIndexShape() {
  const points = Array.from({length:20}, () => [0,0,0]);
  // First index segment turns down/right from wrist; angle magnitude is
  // positive, while direction must come from the VRM side convention.
  points[4]=[0,0.2,0]; points[5]=[0.1,0.3,0];
  points[6]=[0.2,0.4,0]; points[7]=[0.3,0.5,0];
  return points;
}

for (const side of ['left','right']) {
  test(`${side} index flexion bends down, never up`, () => {
    const {ctx,hand,intermediate,distal}=fingerRuntime(side);
    ctx.moverMano(side, true, bentIndexShape());
    hand.updateMatrixWorld(true);
    const tip = distal.getWorldPosition(new THREE.Vector3());
    assert.ok(tip.y < 0, `${side} finger bent upward: y=${tip.y}`);
  });
}

function armRuntime(retargetMode='legacy') {
  const root=new THREE.Object3D(), up=new THREE.Object3D();
  const lo=new THREE.Object3D(), wrist=new THREE.Object3D();
  root.add(up); up.add(lo); lo.add(wrist);
  lo.position.x=.3; wrist.position.x=.25; root.updateMatrixWorld(true);
  const r={dirUp:vector(1,0,0), dirLo:vector(1,0,0), lenUp:.3,lenLo:.25,
    qUp:new THREE.Quaternion(),qLo:new THREE.Quaternion()};
  const ctx=runtime(['vectorBaseAvatar','perfilAvatarRetarget',
    'deltaMunecaRetarget','resolverBrazo'],{
    retargetMode, perfilAvatarCache:null, retargetArm, createAvatarRigProfile,
    refRostro:null, faceAnchorsFromEyes:()=>null,
    kBase:base,
    refRig:{left:r,right:r}, bone:n=>n==='upper'?up:lo,
    VRMHumanBoneName:{LeftUpperArm:'upper',LeftLowerArm:'lower'},
    cal:{invertZ:false,leftArmGain:1,ikMin:.05,ikMax:2.60},
    avDerecha:vector(1,0,0),avArriba:vector(0,1,0),avFrente:vector(0,0,1),
    anchoHombrosAvatar:1,
  });
  return {ctx,root,up,lo,wrist};
}
for (const target of [[2,0,0],[.001,0,0],[.3,.2,0]]) {
  test(`IK respects elbow limits and bone lengths for target ${target}`, () => {
    const {ctx,root,up,lo,wrist}=armRuntime();
    ctx.resolverBrazo('left',base,vector(0,0,0),vector(.1,-.2,0),vector(...target));
    root.updateMatrixWorld(true);
    const a=up.getWorldPosition(vector()), b=lo.getWorldPosition(vector()), c=wrist.getWorldPosition(vector());
    assert.ok(Math.abs(a.distanceTo(b)-.3)<1e-8);
    assert.ok(Math.abs(b.distanceTo(c)-.25)<1e-8);
    const angle=b.clone().sub(a).angleTo(c.clone().sub(b));
    assert.ok(angle >= .05-1e-6 && angle <= 2.60+1e-6, `elbow ${angle}`);
    assert.ok(Math.abs(c.y/Math.max(c.length(),1e-9)-vector(...target).normalize().y)<1e-6,
      'clamped wrist left target ray');
  });
}

const signGolden = JSON.parse(readFileSync(
  new URL('../../test/golden/sign_space_cases.json', import.meta.url), 'utf8'));
const hangingFrame = () => {
  const c = signGolden.cases.find((x) => x.name === 'de_pie');
  return signSpaceFrame(c.pose, c.pose_mundo);
};
// 152D falso: muneca a la derecha a la altura del hombro.
const legacyWrist = vector(.4, 0, 0);

test('anchors mode drives the arm from SignSpace directions', () => {
  const {ctx,root,up,wrist}=armRuntime('anchors');
  ctx.resolverBrazo('left',base,vector(0,0,0),vector(.1,-.2,0),legacyWrist,
    {signSpace: hangingFrame()});
  root.updateMatrixWorld(true);
  const d = wrist.getWorldPosition(vector()).sub(up.getWorldPosition(vector()));
  // brazo izquierdo del usuario cuelga: el avatar cuelga, ignora 152D
  assert.ok(d.clone().normalize().y < -0.99, `y=${d.clone().normalize().y}`);
});

test('legacy mode ignores SignSpace and keeps historic behavior', () => {
  const run = (meta) => {
    const {ctx,root,wrist}=armRuntime('legacy');
    ctx.resolverBrazo('left',base,vector(0,0,0),vector(.1,-.2,0),legacyWrist,meta);
    root.updateMatrixWorld(true);
    return wrist.getWorldPosition(vector());
  };
  const a = run({}), b = run({signSpace: hangingFrame()});
  assert.ok(a.distanceTo(b) < 1e-12);
  assert.ok(a.y > -1e-6, 'legacy sigue a la muneca 152D');
});

test('anchors mode falls back to legacy when the arm is masked', () => {
  const frame = hangingFrame();
  frame.mask.armL = false;
  const {ctx,root,wrist}=armRuntime('anchors');
  ctx.resolverBrazo('left',base,vector(0,0,0),vector(.1,-.2,0),legacyWrist,
    {signSpace: frame});
  root.updateMatrixWorld(true);
  assert.ok(wrist.getWorldPosition(vector()).y > -1e-6);
});

// Profundidad: sign_norm entrega +z = al frente de la persona (hacia la
// camara) y el avatar mira a +Z (hacia la camara). Con la calibracion de
// PRODUCCION una mano delante del cuerpo debe quedar delante del avatar.
const productionInvertZ = /invertZ:\s*true/.test(calBlock);

test('production default puts a forward wrist in front of the avatar', () => {
  const {ctx,root,up,wrist}=armRuntime();
  ctx.cal.invertZ = productionInvertZ;
  // brazo estirado al frente: muneca a 0.9 anchos delante del hombro
  ctx.resolverBrazo('left',base,vector(0,0,0),vector(0,0,.45),vector(0,0,.9));
  root.updateMatrixWorld(true);
  const d = wrist.getWorldPosition(vector()).sub(up.getWorldPosition(vector()));
  assert.ok(d.z > 0.4, `muneca detras del avatar: z=${d.z}`);
});

test('production default keeps hand shape chirality (finger toward camera)', () => {
  const ctx = mathRuntime();
  ctx.cal.invertZ = productionInvertZ;
  // sign_norm: x,y de la forma ya en marco de la persona; z en convencion de
  // imagen (negativa = mas cerca de la camara = al frente de la persona).
  const haciaCamara = ctx.vectorManoAAvatar([0, 0, -1], base);
  assert.ok(haciaCamara.z > 0.99, `dedo hacia la camara invertido: z=${haciaCamara.z}`);
});

test('capture warm-up keeps late first frames off the avatar and ends once', () => {
  const eventos = [];
  const ctx = runtime(['reiniciarCalentamientoWeb', 'enCalentamientoWeb'], {
    kCalentamientoMaxMs: 200, kCalentamientoFrames: 3, kCalentamientoTopeMs: 3000,
    calentamientoWeb: {activo: true, inicio: 0, buenos: 0, descartados: 0},
    eventoSesion: (type, data) => eventos.push([type, data]),
  });
  // Worker recien creado: 2.5 s, 1.3 s, luego normal.
  assert.equal(ctx.enCalentamientoWeb(2500, 1000), true);
  assert.equal(ctx.enCalentamientoWeb(1300, 1066), true);
  assert.equal(ctx.enCalentamientoWeb(40, 1133), true);
  assert.equal(ctx.enCalentamientoWeb(250, 1200), true); // racha cortada
  assert.equal(ctx.enCalentamientoWeb(40, 1266), true);
  assert.equal(ctx.enCalentamientoWeb(38, 1333), true);
  assert.equal(ctx.enCalentamientoWeb(41, 1400), false);
  // Objetos del contexto vm: comparar por valor serializado.
  assert.equal(JSON.stringify(eventos),
    JSON.stringify([['capture_warmup', {discarded: 6, ms: 400}]]));
  // Despues del calentamiento un frame lento sigue moviendo el avatar.
  assert.equal(ctx.enCalentamientoWeb(900, 1466), false);
  assert.equal(eventos.length, 1);

  // Equipo lento: nunca baja de 200 ms, el tope de 3 s termina igual.
  ctx.reiniciarCalentamientoWeb();
  assert.equal(ctx.enCalentamientoWeb(400, 0 + 1), true);
  assert.equal(ctx.enCalentamientoWeb(400, 3002), false);
});

test('embedded perf carries smoothness and avatar state like the web perf', () => {
  const start = html.indexOf('window.configurarSesion = function');
  assert.ok(start > 0, 'configurarSesion exists');
  const block = html.slice(start, html.indexOf('\n    };', start));
  for (const field of ['render_motion: drenarFluidezRender()',
    'avatar_state: webCameraState.avatarState',
    'safety_adjustments: safetyAjustes',
    'safety_clamped_joints: safetyAjustesArticulaciones']) {
    assert.ok(block.includes(field), `perf embebido sin ${field}`);
  }
  // animar() usa el presupuesto de reposo solo en el telefono.
  assert.match(html, /idleBudgetFor\(presupuestoRender\)/);
});

test('live frames tell Dart quiet/motion with the same adaptive filter as web', () => {
  assert.match(html, /window\.configurarMovimiento = function/);
  const start = html.indexOf('window.aplicarFrameVivo = function');
  const block = html.slice(start, html.indexOf('\n    };', start));
  // Despues del filtro adaptativo, no antes: usa sus diagnosticos del frame.
  const filtro = block.indexOf('frameVivo = suavizarFrameWeb(');
  const aviso = block.indexOf("'motion:'");
  assert.ok(filtro > 0 && aviso > filtro, 'motion: sale despues de suavizarFrameWeb');
  assert.ok(block.includes('intentionalMotion'), 'usa el umbral intencional del filtro');
  assert.ok(block.includes('fingerMotionScore'), 'cuenta los dedos');
});

test('page capture delegates to the shared modules (rig_hand_capture, rig_motion_frame)', () => {
  // La logica vive en los modulos y la fija el banco de paridad
  // (paridad_manos.test.mjs); la pagina solo registra diagnostico y sesion.
  assert.match(sourceBlock('manosDesdeResultado'), /webHandCapture\.process\(/);
  assert.match(sourceBlock('normalizarFrameWeb'), /normalizeMotionFrame\(/);
  assert.match(sourceBlock('webManoUtilizable'), /handUsable\(/);
  assert.match(sourceBlock('webPoseGeometriaValida'), /poseGeometry\(/);
  assert.match(sourceBlock('calcularCalidadFrameWeb'), /frameQuality\(/);
  assert.match(html, /webHandCapture\.reset\(\)/);
});
