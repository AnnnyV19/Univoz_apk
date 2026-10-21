// Punto de entrada del paquete que usa el visor (window.UnivozVendor).
// Exporta exactamente los nombres que index.html tomaba antes del CDN.
import * as THREE from 'three';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';
import { VRMLoaderPlugin, VRMUtils, VRMHumanBoneName } from '@pixiv/three-vrm';

export { THREE, GLTFLoader, OrbitControls, VRMLoaderPlugin, VRMUtils, VRMHumanBoneName };
