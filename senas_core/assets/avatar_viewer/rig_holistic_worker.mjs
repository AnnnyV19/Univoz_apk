// HolisticLandmarker en un Web Worker.
//
// detectForVideo es sincrono y tarda ~45 ms por frame (GPU, 2026-10-03):
// en el hilo principal bloquea el render del avatar y el lazo rAF suma la
// espera al siguiente frame (~57 ms entre frames, ~17 FPS). En un worker la
// inferencia corre aparte, el avatar sigue a 60 FPS y el siguiente frame se
// manda en cuanto el worker queda libre (tubo de un frame).
//
// El worker se crea desde un Blob (sin archivo propio): el visor tambien
// vive inline en Android y Flutter Web. Por eso todas las URL que recibe
// deben ser absolutas. Solo GPU: si falla, el visor vuelve a la cadena del
// hilo principal (GPU y luego CPU), que ya existe.

// Cuerpo del worker. Se serializa con toString(): no puede usar nada de
// fuera de la funcion. `scope` es el self del worker e `importar` hace el
// import() dinamico (inyectables para las pruebas).
export function holisticWorkerMain(scope, importar) {
  let tarea = null;
  const responder = (msg) => scope.postMessage(msg);
  const lista = (v) => (Array.isArray(v) ? v : []);
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
  scope.onmessage = async (event) => {
    const msg = event.data || {};
    if (msg.type === 'init') {
      const fallos = [];
      try {
        const vision = await importar(msg.bundleUrl);
        const fileset = await vision.FilesetResolver.forVisionTasks(msg.wasmUrl);
        // Un worker de modulo no tiene importScripts y MediaPipe no llega a
        // definir ModuleFactory ("ModuleFactory not set"): se evalua el
        // cargador wasm a mano en el ambito global.
        if (!scope.ModuleFactory && fileset?.wasmLoaderPath && msg.loadWasmLoader !== false) {
          const codigo = await (await fetch(fileset.wasmLoaderPath)).text();
          (0, eval)(codigo + '\n;self.ModuleFactory = ModuleFactory;');
        }
        for (const modelo of msg.models) {
          try {
            tarea = await vision.HolisticLandmarker.createFromOptions(fileset, {
              ...msg.options,
              baseOptions: {modelAssetPath: modelo, delegate: 'GPU'},
              runningMode: 'VIDEO',
            });
            responder({type: 'ready', model: modelo, failures: fallos});
            return;
          } catch (error) {
            fallos.push({model: modelo, error: String(error?.message ?? error)});
          }
        }
        responder({type: 'init_error', failures: fallos});
      } catch (error) {
        fallos.push({model: null, error: String(error?.message ?? error)});
        responder({type: 'init_error', failures: fallos});
      }
      return;
    }
    if (msg.type === 'detect') {
      const inicio = performance.now();
      try {
        if (!tarea) throw new Error('holistic worker sin inicializar');
        const result = plano(tarea.detectForVideo(msg.frame, msg.timestampMs));
        responder({type: 'result', id: msg.id, result,
          ms: performance.now() - inicio});
      } catch (error) {
        responder({type: 'detect_error', id: msg.id,
          error: String(error?.message ?? error)});
      } finally {
        try { msg.frame?.close?.(); } catch (_) { /* ya cerrado */ }
      }
      return;
    }
    if (msg.type === 'close') {
      try { tarea?.close(); } catch (_) { /* nada que liberar */ }
      tarea = null;
    }
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

// Cliente: init() -> {model, failures}; detect(frame, t) -> {result, ms}.
// Un detect a la vez es responsabilidad del llamador; aun asi las respuestas
// se correlacionan por id. Cualquier error rechaza la promesa pendiente.
export function createHolisticWorkerClient({
  bundleUrl, wasmUrl, models, options = {},
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
      listo?.resolve({model: msg.model, failures: msg.failures ?? []});
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
      if (msg.type === 'result') p.resolve({result: msg.result, ms: msg.ms});
      else p.reject(new Error(msg.error));
    }
  };
  worker.onerror = (event) => {
    event?.preventDefault?.();
    rechazarTodo(new Error('holistic worker: ' + (event?.message ?? 'error')));
  };

  return {
    init() {
      return new Promise((resolve, reject) => {
        let temporizador = null;
        const fin = (fn) => (v) => { clearTimeout(temporizador); fn(v); };
        listo = {resolve: fin(resolve), reject: fin(reject)};
        temporizador = setTimeout(() => {
          listo?.reject(new Error('holistic worker: init timeout'));
          listo = null;
        }, initTimeoutMs);
        worker.postMessage({type: 'init', bundleUrl, wasmUrl, models, options});
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
