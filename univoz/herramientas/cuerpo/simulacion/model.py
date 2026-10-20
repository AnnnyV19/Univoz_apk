import numpy as np, json
from glb import load, accessor
import os
PATH=os.environ.get('UNIVOZ_VRM', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'assets', 'avatar', 'MODELO_UNIVOZ_v0.vrm'))
def qmat(q):
    x,y,z,w=q
    return np.array([[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],[2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],[2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]])
def local(n):
    M=np.eye(4)
    if 'matrix' in n:
        M=np.array(n['matrix']).reshape(4,4).T
    else:
        S=np.diag(n.get('scale',[1,1,1])); R=qmat(n.get('rotation',[0,0,0,1]))
        M[:3,:3]=R@S; M[:3,3]=n.get('translation',[0,0,0])
    return M
class Model:
    def __init__(s, path=PATH):
        s.js, s.bin = load(path)
        nodes=s.js['nodes']; s.parent={}
        for i,n in enumerate(nodes):
            for c in n.get('children',[]): s.parent[c]=i
        s.world={}
        def w(i):
            if i in s.world: return s.world[i]
            M=local(nodes[i]); p=s.parent.get(i)
            s.world[i]= (w(p)@M) if p is not None else M
            return s.world[i]
        for i in range(len(nodes)): w(i)
        hb=s.js['extensions']['VRM']['humanoid']['humanBones']
        s.hum={h['bone']:h['node'] for h in hb}
        s.pos={k:s.world[v][:3,3].copy() for k,v in s.hum.items()}
        # meshes: gather all skinned primitives
        s.verts=[]; s.joints=[]; s.weights=[]; s.mesh_name=[]; s.faces=[]
        base=0
        for ni,n in enumerate(nodes):
            if 'mesh' not in n: continue
            skin = s.js['skins'][n['skin']] if 'skin' in n else None
            jointnodes = skin['joints'] if skin else None
            mesh = s.js['meshes'][n['mesh']]
            for pr in mesh['primitives']:
                at=pr['attributes']
                P=accessor(s.js,s.bin,at['POSITION']).astype(np.float64)
                Wm = s.world[ni]
                Pw=(Wm[:3,:3]@P.T).T+Wm[:3,3]
                if 'JOINTS_0' in at and jointnodes is not None:
                    J=accessor(s.js,s.bin,at['JOINTS_0']).astype(int); Wt=accessor(s.js,s.bin,at['WEIGHTS_0']).astype(np.float64)
                    Jn=np.array(jointnodes)[J]
                else:
                    Jn=np.full((len(P),4),ni); Wt=np.tile([1,0,0,0],(len(P),1)).astype(float)
                idx=accessor(s.js,s.bin,pr['indices']).reshape(-1,3)+base if 'indices' in pr else None
                s.verts.append(Pw); s.joints.append(Jn); s.weights.append(Wt)
                s.mesh_name.append(np.full(len(P), mesh.get('name', str(n['mesh'])) + ':' + str(pr.get('material'))))
                if idx is not None: s.faces.append(idx)
                base+=len(P)
        s.verts=np.concatenate(s.verts); s.joints=np.concatenate(s.joints); s.weights=np.concatenate(s.weights); s.mesh_name=np.concatenate(s.mesh_name)
        s.faces=np.concatenate(s.faces) if s.faces else None
        s.node2bone={v:k for k,v in s.hum.items()}
    def dom_bone(s):
        # dominant joint node -> humanoid bone name (or node name)
        k=np.argmax(s.weights,axis=1)
        dn=s.joints[np.arange(len(k)),k]
        return np.array([s.node2bone.get(int(d), 'n%d'%int(d)) for d in dn])
if __name__=='__main__':
    m=Model()
    print('verts',len(m.verts),'faces',None if m.faces is None else len(m.faces))
    for k in ['hips','spine','chest','upperChest','neck','head','leftShoulder','leftUpperArm','rightUpperArm','leftLowerArm','leftHand','leftMiddleProximal','leftMiddleDistal','leftEye','rightEye','leftUpperLeg']:
        print(k, np.round(m.pos[k],4))
    print('bounds',m.verts.min(0),m.verts.max(0))
    import collections
    print(collections.Counter(m.mesh_name).most_common(10))
    db=m.dom_bone(); print(collections.Counter(db).most_common(25))
