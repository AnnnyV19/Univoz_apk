import numpy as np
from scipy.special import gamma
from torso import build
m,t,h=build()
ysh=m.pos['leftUpperArm'][1]; zs=m.pos['leftUpperArm'][2]
W=np.linalg.norm(m.pos['leftUpperArm']-m.pos['rightUpperArm'])
ys=[];A=[];ZF=[];ZB=[]
for i,y in enumerate(t.ys):
    P=t.poly[i]
    if P is None or y<0.80 or y>1.40: continue
    ys.append(y);A.append(np.abs(P[:,0]).max());ZF.append(P[:,1].min());ZB.append(P[:,1].max())
ys=np.array(ys);A=np.array(A);ZF=np.array(ZF);ZB=np.array(ZB)
def smooth(v,k=3):
    out=np.copy(v)
    for i in range(len(v)):
        lo=max(0,i-k);hi=min(len(v),i+k+1); out[i]=np.median(v[lo:hi])*0.5+np.mean(v[lo:hi])*0.5
    return out
As=smooth(A);ZFs=smooth(ZF);ZBs=smooth(ZB)
keys=np.arange(0.84,1.361,0.04)
tab=[]
for k in keys:
    a=np.interp(k,ys,As); zf=np.interp(k,ys,ZFs); zb=np.interp(k,ys,ZBs)
    tab.append((k-ysh, a, zs-zf, zs-zb))
tab=np.array(tab)
print('v(m)      a      wf     wb   (v rel to shoulder y; w forward of shoulder plane)')
for r in tab: print('%+.3f  %.3f  %+.3f  %+.3f'%tuple(r))
np.save('tabla_torso.npy',tab)
# error vs hull: sample grid
from torso import poly_signed
N=2.4
def sd_table(v,u,w):
    # superellipse implicit based "distance" (approx): return inside amount in meters along radial dir
    if v<tab[0,0] or v>tab[-1,0]: return -1
    a=np.interp(v,tab[:,0],tab[:,1]); wf=np.interp(v,tab[:,0],tab[:,2]); wb=np.interp(v,tab[:,0],tab[:,3])
    wc=(wf+wb)/2; b=(wf-wb)/2
    f=(abs(u)/a)**N+(abs(w-wc)/b)**N
    return 1-f  # >0 inside
# compare inside/outside classification vs hull on random points
rng=np.random.default_rng(1); agree=0;tot=0; fn=0;fp=0
for _ in range(4000):
    y=rng.uniform(0.9,1.26); x=rng.uniform(-0.2,0.2); z=rng.uniform(-0.2,0.15)
    d=t.depth(np.array([x,y,z]))
    inside_h=d>0
    inside_t=sd_table(y-ysh,x,-(z-zs))>0
    tot+=1; agree+=(inside_h==inside_t); fp+=(inside_t and not inside_h); fn+=(inside_h and not inside_t)
print('acuerdo %.3f  falsos+ %d falsos- %d de %d'%(agree/tot,fp,fn,tot))
