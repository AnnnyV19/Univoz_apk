import numpy as np
from scipy.spatial import ConvexHull
from model import Model

class Solid:
    """Per-height-slice convex polygons (x,z) of a body part, from the rest-pose mesh (file frame)."""
    def __init__(s, V, step=0.01, thick=0.02):
        s.step=step
        s.ys=np.arange(V[:,1].min()+thick/2, V[:,1].max()-thick/2, step)
        s.poly=[]
        for y in s.ys:
            v=V[np.abs(V[:,1]-y)<thick/2]
            if len(v)<8: s.poly.append(None); continue
            pts=v[:,[0,2]]
            try:
                h=ConvexHull(pts); s.poly.append(pts[h.vertices])
            except Exception:
                s.poly.append(None)
    def depth(s, p):
        """Penetration depth (m) of point p=(x,y,z file frame): >0 inside (distance to nearest boundary), <=0 outside (negative distance to polygon)."""
        y=p[1]
        i=int(round((y-s.ys[0])/s.step))
        if i<0 or i>=len(s.ys): return -1.0
        P=s.poly[i]
        if P is None: return -1.0
        return poly_signed(P,(p[0],p[2]))
def poly_signed(P,q):
    # convex polygon given CCW or CW; compute signed distance: positive inside
    n=len(P); best=1e9; inside=True
    # orientation
    area=0
    for i in range(n):
        a=P[i];b=P[(i+1)%n]; area+=a[0]*b[1]-b[0]*a[1]
    sgn=1 if area>0 else -1
    for i in range(n):
        a=P[i];b=P[(i+1)%n]
        e=b-a; L=np.hypot(*e)
        if L<1e-9: continue
        nrm=np.array([-e[1],e[0]])/L*sgn  # inward normal for CCW
        d=(q[0]-a[0])*nrm[0]+(q[1]-a[1])*nrm[1]
        best=min(best,d)
    return best
def build():
    m=Model(); db=m.dom_bone()
    body=np.array([n.startswith('Body') for n in m.mesh_name])
    face=np.array([n.startswith('Face') for n in m.mesh_name])
    torso=Solid(m.verts[body&np.isin(db,['hips','spine','chest','upperChest','neck'])])
    head=Solid(m.verts[(body|face)&(db=='head')])
    return m,torso,head
if __name__=='__main__':
    m,t,h=build()
    for y in [0.9,1.0,1.1,1.2,1.25,1.3,1.4,1.5]:
        i=int(round((y-t.ys[0])/t.step)); 
        P=t.poly[i] if 0<=i<len(t.poly) else None
        print(y, None if P is None else (P[:,0].min().round(3),P[:,0].max().round(3),P[:,1].min().round(3),P[:,1].max().round(3)))
    print('head y range',h.ys[0],h.ys[-1])
