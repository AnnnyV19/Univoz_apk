import json, struct, numpy as np, sys
def load(path):
    b = open(path,'rb').read()
    magic, ver, length = struct.unpack_from('<III', b, 0)
    off = 12; js=None; binc=None
    while off < len(b):
        clen, ctype = struct.unpack_from('<II', b, off); off += 8
        data = b[off:off+clen]; off += clen
        if ctype == 0x4E4F534A: js = json.loads(data.decode('utf8'))
        elif ctype == 0x004E4942: binc = data
    return js, binc
COMP = {5120:np.int8,5121:np.uint8,5122:np.int16,5123:np.uint16,5125:np.uint32,5126:np.float32}
NCOMP = {'SCALAR':1,'VEC2':2,'VEC3':3,'VEC4':4,'MAT4':16}
def accessor(js, binc, idx):
    a = js['accessors'][idx]; bv = js['bufferViews'][a['bufferView']]
    dt = np.dtype(COMP[a['componentType']]); n = NCOMP[a['type']]
    start = bv.get('byteOffset',0) + a.get('byteOffset',0)
    stride = bv.get('byteStride', 0)
    count = a['count']
    if stride and stride != dt.itemsize*n:
        arr = np.ndarray((count, n), dtype=dt, buffer=binc, offset=start, strides=(stride, dt.itemsize))
        return np.array(arr)
    return np.frombuffer(binc, dtype=dt, count=count*n, offset=start).reshape(count, n).copy()
if __name__ == '__main__':
    js, binc = load(sys.argv[1])
    print(js.keys()); print(js['asset'])
    print(list(js.get('extensions',{}).keys()))
    print(len(js['nodes']), 'nodes', len(js['meshes']),'meshes', len(js['skins']),'skins')
    ext = js['extensions']
    if 'VRM' in ext:
        hb = ext['VRM']['humanoid']['humanBones']
        print([(h['bone'],h['node']) for h in hb][:60])
