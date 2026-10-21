import numpy as np, sys, pickle
from multiprocessing import Pool
from separar4 import *
from simular import m
_z=np.load('primeras.npz'); S_={g:_z[g] for g in _z.files}; GL=list(S_.keys())
STEP=int(sys.argv[1]) if len(sys.argv)>1 else 1
DIRUP={'L':None,'R':None}
for lado,(u,l) in {'L':('leftUpperArm','leftLowerArm'),'R':('rightUpperArm','rightLowerArm')}.items():
    d=m.pos[l]-m.pos[u]; DIRUP[lado]=d/np.linalg.norm(d)
ysh=SH['L'][1]; zs=SH['L'][2]
MARCO=dict(escala=1.0,T=np.hstack([np.eye(3),np.zeros((3,1))]),origen=np.array([0,ysh,zs]),der=np.array([1.0,0,0]),arr=np.array([0,1.0,0]),fre=np.array([0,0,-1.0]))
FRENTE=np.array([0,0,-1.0]); ARRIBA=np.array([0,1.0,0])
rmin=max(abs(LU-LL)+1e-5, radio_ang(IKMAX)); rmax=min(LU+LL-1e-5, radio_ang(IKMIN))
def hull_pen(elb,wri,shape):
    hp=hand_pts(wri,shape)
    pts=[(wri,0.028),(elb,0.038)]
    for t in (0.25,0.5,0.75): pts.append((elb+(wri-elb)*t,0.04-0.01*t))
    for i in range(20):
        r=0.022 if i in (0,4,8,12,16) else (0.004 if i in (3,7,11,15,19) else 0.009)
        pts.append((hp[i],r))
    hand=max(torso.depth(p)+r for p,r in [pts[0]]+pts[5:])
    arm=max(torso.depth(p)+r for p,r in pts[1:5])
    return hand,arm
def entrada(lado,f):
    offLoc,offPres,offShape,iSh,iEl={'L':(24,30,32,0,2),'R':(27,31,92,1,3)}[lado]
    body=f[0:24].reshape(8,3); sh=body[iSh]; el=body[iEl]; wr=f[offLoc:offLoc+3]; shape=f[offShape:offShape+60]
    delta=tpl2file(wr-sh)*W; cod=tpl2file(el-sh)*W
    mano_off=hand_pts(np.zeros(3),shape)
    return SH[lado],delta,cod,mano_off,shape
def work(g):
    seq=S_[g]; out=[]; prev={'L':None,'R':None}
    for fi in range(0,len(seq),STEP):
        f=seq[fi]
        for lado,(offPres,iEl) in {'L':(30,2),'R':(31,3)}.items():
            if f[offPres]<0.5 or np.hypot(*f[iEl*3:iEl*3+2])<=0.05: prev[lado]=None; continue
            sh,delta,cod,mano_off,shape=entrada(lado,f)
            res=resolver(sh,delta,cod,DIRUP[lado],rmin,rmax,FRENTE,ARRIBA,mano_off,MARCO,previo=prev[lado])
            prev[lado]=res['giro']
            e0,w0=ik(sh,delta,cod,DIRUP[lado],rmin,rmax,0.0)
            h0,a0=hull_pen(e0,w0,shape)
            e1,w1=ik(sh,res['delta'],cod,DIRUP[lado],rmin,rmax,res['giro'])
            h1,a1=hull_pen(e1,w1,shape)
            out.append((g,fi,lado,h0,a0,h1,a1,res['empuje'],np.degrees(res['giro']),w0[1]-w1[1],res['iter'],np.degrees(res['giroObjetivo'])))
    return out
if __name__=='__main__':
    with Pool(2) as p: res=p.map(work,GL,chunksize=8)
    rows=[r for x in res for r in x]
    pickle.dump(rows,open('validar4_rows.pkl','wb'))
    A=np.array([[r[3],r[4],r[5],r[6],r[7],r[8],r[9],r[11]] for r in rows])
    print('hand-frames',len(A))
    for name,j in (('mano/muñeca antes',0),('antebrazo/codo antes',1),('mano/muñeca despues',2),('antebrazo/codo despues',3)):
        print(name,' >0.5cm %.1f%%  >1cm %.1f%%  >2cm %.1f%%  max %.3f'%(100*(A[:,j]>0.005).mean(),100*(A[:,j]>0.01).mean(),100*(A[:,j]>0.02).mean(),A[:,j].max()))
    print('max |dy muñeca| = %.2e m'%np.abs(A[:,6]).max())
    P=A[:,4]; print('empuje: >0.5cm %.1f%% p50 %.3f p90 %.3f p99 %.3f max %.3f'%(100*(P>0.005).mean(),*np.percentile(P,[50,90,99,100])))
    T=np.abs(A[:,5]); print('giro codo: |th|>5° %.1f%% p90 %.0f max %.0f'%(100*(T>5).mean(),np.percentile(T,90),T.max()))
