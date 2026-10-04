// Captura MediaPipe en un Web Worker.
//
// detectForVideo es sincrono y tarda ~45 ms por frame (GPU, 2026-10-03):
// en el hilo principal bloquea el render del avatar y el lazo rAF suma la
// espera al siguiente frame (~57 ms entre frames, ~17 FPS). En un worker la
// inferencia corre aparte, el avatar sigue a 60 FPS y el siguiente frame se
// manda en cuanto el worker queda libre (tubo de un frame).
//
// Dos modos: 'holistic' (un modelo, producto por defecto) y 'separado'
// (Pose lite + Hand + Face). Medido en Chromium GPU (2026-10-04, mismo frame):
// Holistic p50 29 ms; Pose 7 + Hand 6 + Face 9 = ~22 ms.
//
// El worker se crea desde un Blob (sin archivo propio): el visor tambien
// vive inline en Android y Flutter Web. Por eso todas las URL que recibe
// deben ser absolutas. Solo GPU: si falla, el visor vuelve a la cadena del
// hilo principal (GPU y luego CPU), que ya existe.

// Cuerpo del worker. Se serializa con toString(): no puede usar nada de
// fuera de la funcion. `scope` es el self del worker e `importar` hace el
// import() dinamico (inyectables para las pruebas).
export function holisticWorkerMain(scope, importar) {
  let modo = 'holistic';
  let tarea = null;
  let tareas = null;
  const responder = (msg) => scope.postMessage(msg);
  const lista = (v) => (Array.isArray(v) ? v : []);
  const error = (e) => String(e?.message ?? e);
  // Solo los campos que usa holisticToTaskResults, como objetos planos.
  const plano = (r) => ({
    poseLandmarks: lista(r?.poseLandmarks),
    poseWorldLandmarks: lista(r?.poseWorldLandmarks),
    leftHandLandmarks: lista(r?.leftHandLandmarks),
    leftHandWorldLandmarks: lista(r?.leftHandWorldLandmarks),
    rightHandLandmarks: lista(r?.rightHandLandmarks),
    rightHandWorldLandmarks: lista(r?.rightHandWorldLandmarks),
    faceLandmarks: lista(r?.faceLandmarks),
    faceBlendshapes: lista(r?.faceBlendshapes).map((b) => ({
      categories: lista(b?.categories).map((c) => ({
        categoryName: c.categoryName, score: c.score})),
    })),
  });
  const categorias = (grupos) => lista(grupos).map((g) => lista(g).map((c) => ({
    categoryName: c.categoryName, score: c.score, index: c.index})));
  scope.onmessage = async (event) => {
    const msg = event.data || {};
    if (msg.type === 'init') {
      const fallos = [];
      try {
        const vision = await importar(msg.bundleUrl);
        const fileset = await vision.FilesetResolver.forVisionTasks(msg.wasmUrl);
        // Un worker de modulo no tiene importScripts y MediaPipe no llega a
        // definir ModuleFactory ("ModuleFactory not set"): se evalua el
        // cargador wasm a mano en el ambito global. MediaPipe lo borra tras
        // crear cada tarea, asi que se repone antes de cada creacion.
        let cargador = null;
        if (fileset?.wasmLoaderPath && msg.loadWasmLoader !== false) {
          cargador = await (await fetch(fileset.wasmLoaderPath)).text();
        }
        const reponerCargador = () => {
          if (cargador && !scope.ModuleFactory) {
            (0, eval)(cargador + '\n;self.ModuleFactory = ModuleFactory;');
          }
        };
        // Primer modelo de la lista que carga en GPU, o null.
        const crear = async (Clase, modelos, opciones) => {
          for (const modelo of lista(modelos)) {
            try {
              reponerCargador();
              const t = await Clase.createFromOptions(fileset, {
                ...opciones,
                baseOptions: {modelAssetPath: modelo, delegate: 'GPU'},
                runningMode: 'VIDEO',
              });
              return {tarea: t, modelo};
            } catch (e) {
              fallos.push({model: modelo, error: error(e)});
            }
          }
          return null;
        };
        modo = msg.mode === 'separado' ? 'separado' : 'holistic';
        if (modo === 'holistic') {
          const r = await crear(vision.HolisticLandmarker, msg.models, msg.options);
          if (r) {
            tarea = r.tarea;
            responder({type: 'ready', mode: modo, model: r.modelo, failures: fallos});
            return;
          }
        } else {
          const o = msg.options || {};
          const pose = await crear(vision.PoseLandmarker, msg.models?.pose, o.pose);
          const hand = pose &&
            await crear(vision.HandLandmarker, msg.models?.hand, o.hand);
          if (pose && hand) {
            // La cara es opcional: sin ella sigue el cuerpo y las manos.
            const face = await crear(vision.FaceLandmarker, msg.models?.face, o.face);
            tareas = {pose: pose.tarea, hand: hand.tarea, face: face?.tarea ?? null};
            responder({type: 'ready', mode: modo, failures: fallos, model: {
              pose: pose.modelo, hand: hand.modelo, face: face?.modelo ?? null}});
            return;
          }
          try { pose?.tarea.close(); } catch (_) { /* nada */ }
        }
        responder({type: 'init_error', failures: fallos});
      } catch (e) {
        fallos.push({model: null, error: error(e)});
        responder({type: 'init_error', failures: fallos});
      }
      return;
    }
    if (msg.type === 'detect') {
      const inicio = performance.now();
      try {
        let result, stages;
        if (modo === 'holistic') {
          if (!tarea) throw new Error('worker de captura sin inicializar');
          result = plano(tarea.detectForVideo(msg.frame, msg.timestampMs));
        } else {
          if (!tareas) throw new Error('worker de captura sin inicializar');
          const t0 = performance.now();
          const pose = tareas.pose.detectForVideo(msg.frame, msg.timestampMs);
          const t1 = performance.now();
          const hand = tareas.hand.detectForVideo(msg.frame, msg.timestampMs);
          const t2 = performance.now();
          const face = tareas.face?.detectForVideo(msg.frame, msg.timestampMs);
          const t3 = performance.now();
          stages = {pose: t1 - t0, hand: t2 - t1, face: t3 - t2};
          result = {
            pose: {landmarks: lista(pose?.landmarks),
              worldLandmarks: lista(pose?.worldLandmarks)},
            hand: {landmarks: lista(hand?.landmarks),
              worldLandmarks: lista(hand?.worldLandmarks),
              handednesses: categorias(hand?.handednesses ?? hand?.handedness)},
            face: {faceLandmarks: lista(face?.faceLandmarks)},
          };
        }
        responder({type: 'result', id: msg.id, result, stages,
          ms: performance.now() - inicio});
      } catch (e) {
        responder({type: 'detect_error', id: msg.id, error: error(e)});
      } finally {
        try { msg.frame?.close?.(); } catch (_) { /* ya cerrado */ }
      }
      return;
    }
    if (msg.type === 'close') {
      for (const t of [tarea, tareas?.pose, tareas?.hand, tareas?.face]) {
        try { t?.close(); } catch (_) { /* nada que liberar */ }
      }
      tarea = null;
      tareas = null;
    }
  };
}

// Resultado del modo 'separado' al mismo formato que holisticToTaskResults.
// Las etiquetas de mano siguen siendo solo pista: el lado fisico lo decide
// la cadena del brazo.
export function separadoToTaskResults(result) {
  const pose = result?.pose?.landmarks?.[0] ?? null;
  const poseWorld = result?.pose?.worldLandmarks?.[0] ?? null;
  const caraPts = result?.face?.faceLandmarks?.[0] ?? null;
  return {
    poseResult: pose ? {landmarks: [pose],
      worldLandmarks: poseWorld ? [poseWorld] : []} : null,
    handResult: {
      landmarks: result?.hand?.landmarks ?? [],
      worldLandmarks: result?.hand?.worldLandmarks ?? [],
      handednesses: result?.hand?.handednesses ?? [],
    },
    face: caraPts ? {landmarks: caraPts, blendshapes: {}} : null,
  };
}

export function holisticWorkerSource() {
  return '(' + holisticWorkerMain.toString() +
    ')(self, (url) => import(url));\n';
}

// Disponible solo con Worker de modulo, OffscreenCanvas (GPU en el worker)
// y createImageBitmap (frame transferible).
export function holisticWorkerSupported(g = globalThis) {
  return typeof g.Worker === 'function' &&
    typeof g.OffscreenCanvas === 'function' &&
    typeof g.createImageBitmap === 'function' &&
    typeof g.Blob === 'function' && typeof g.URL?.createObjectURL === 'function';
}

// Cliente: init() -> {mode, model, failures};
// detect(frame, t) -> {result, ms, stages}.
// Un detect a la vez es responsabilidad del llamador; aun asi las respuestas
// se correlacionan por id. Cualquier error rechaza la promesa pendiente.
export function createHolisticWorkerClient({
  mode = 'holistic', bundleUrl, wasmUrl, models, options = {},
  createWorker = (source) => {
    const url = URL.createObjectURL(
      new Blob([source], {type: 'text/javascript'}));
    const worker = new Worker(url, {type: 'module'});
    URL.revokeObjectURL(url);
    return worker;
  },
  initTimeoutMs = 60000,
} = {}) {
  const worker = createWorker(holisticWorkerSource());
  const pendientes = new Map();
  let siguienteId = 1;
  let listo = null;
  let cerrado = false;

  const rechazarTodo = (error) => {
    for (const {reject} of pendientes.values()) reject(error);
    pendientes.clear();
    listo?.reject(error);
    listo = null;
  };
  worker.onmessage = (event) => {
    const msg = event.data || {};
    if (msg.type === 'ready') {
      listo?.resolve({mode: msg.mode ?? mode, model: msg.model,
        failures: msg.failures ?? []});
      listo = null;
    } else if (msg.type === 'init_error') {
      const error = new Error('holistic worker: ' +
        (msg.failures ?? []).map((f) => f.error).join(' | '));
      error.failures = msg.failures ?? [];
      listo?.reject(error);
      listo = null;
    } else if (msg.type === 'result' || msg.type === 'detect_error') {
      const p = pendientes.get(msg.id);
      if (!p) return;
      pendientes.delete(msg.id);
      if (msg.type === 'result') {
        p.resolve({result: msg.result, ms: msg.ms, stages: msg.stages ?? null});
      }
      else p.reject(new Error(msg.error));
    }
  };
  worker.onerror = (event) => {
    event?.preventDefault?.();
    rechazarTodo(new Error('holistic worker: ' + (event?.message ?? 'error')));
  };

  return {
    mode,
    init() {
      return new Promise((resolve, reject) => {
        let temporizador = null;
        const fin = (fn) => (v) => { clearTimeout(temporizador); fn(v); };
        listo = {resolve: fin(resolve), reject: fin(reject)};
        temporizador = setTimeout(() => {
          listo?.reject(new Error('holistic worker: init timeout'));
          listo = null;
        }, initTimeoutMs);
        worker.postMessage({type: 'init', mode, bundleUrl, wasmUrl, models,
          options});
      });
    },
    detect(frame, timestampMs) {
      if (cerrado) {
        try { frame?.close?.(); } catch (_) { /* nada */ }
        return Promise.reject(new Error('holistic worker cerrado'));
      }
      const id = siguienteId++;
      return new Promise((resolve, reject) => {
        pendientes.set(id, {resolve, reject});
        worker.postMessage({type: 'detect', id, frame, timestampMs}, [frame]);
      });
    },
    get pending() { return pendientes.size; },
    close() {
      if (cerrado) return;
      cerrado = true;
      rechazarTodo(new Error('holistic worker cerrado'));
      try { worker.postMessage({type: 'close'}); } catch (_) { /* ya muerto */ }
      worker.terminate?.();
    },
  };
}
