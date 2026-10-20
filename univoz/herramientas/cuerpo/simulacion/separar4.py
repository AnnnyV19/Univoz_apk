"""Referencia en Python del separador de cuerpo v2 (lo que se porta a JS)."""
import numpy as np
from simular import W,LU,LL,PALM,SH,tpl2file,radio_ang,IKMIN,IKMAX,hand_pts,torso
TAB=np.round(np.load('tabla_torso.npy'),5)
ANCHO_REF=0.2171117844
N=2.4; MARGEN=0.004; BANDA_U=0.03; BANDA_V=0.04
TOL=0.0015; MAX_EMPUJE=0.20
THETAS=np.radians(np.arange(-90,91,10))
PASOG=np.radians(10); MAXG=np.radians(90)
V0=TAB[0,0]; V1=TAB[-1,0]
def suave(x):
    x=min(1.0,max(0.0,x)); return x*x*(3-2*x)
def necesidad(q,r):
    u,v,w=q
    if v<=V0 or v>=V1: return 0.0
    a=np.interp(v,TAB[:,0],TAB[:,1]); wf=np.interp(v,TAB[:,0],TAB[:,2]); wb=np.interp(v,TAB[:,0],TAB[:,3])
    R=r+MARGEN; A=a+R; B=(wf-wb)/2+R; wc=(wf+wb)/2
    au=abs(u)
    if au>=A: return 0.0
    t=w-(wc-0.5*B)
    if t<=0: return 0.0
    wsurf=wc+B*(1-(au/A)**N)**(1/N)
    n=wsurf-w
    if n<=0: return 0.0
    g=suave((A-au)/BANDA_U)*suave((v-V0)/BANDA_V)*suave((V1-v)/BANDA_V)*suave(t/(0.5*B))
    return n*g
def ik(sh,delta,codoDes,dirUp,rmin,rmax,theta):
    r=np.linalg.norm(delta)
    rr=min(rmax,max(rmin,r)); dirv=delta/max(r,1e-9)
    wrist=sh+dirv*rr
    pl=codoDes-dirv*codoDes.dot(dirv)
    if pl.dot(pl)<1e-8: pl=dirUp-dirv*dirUp.dot(dirv)
    if pl.dot(pl)<1e-8: pl=np.array([0,1.0,0])
    pl=pl-dirv*pl.dot(dirv); pl/=np.linalg.norm(pl)
    if theta!=0: pl=pl*np.cos(theta)+np.cross(dirv,pl)*np.sin(theta)
    avance=(LU*LU-LL*LL+rr*rr)/(2*rr); alt=np.sqrt(max(0,LU*LU-avance*avance))
    return sh+dirv*avance+pl*alt, wrist
def resolver(sh,delta,codoDes,dirUp,rmin,rmax,frente,arriba,mano_off,marco,previo=None):
    k=marco['escala']; T=marco['T']; org=marco['origen']; der=marco['der']; arr=marco['arr']; fre=marco['fre']
    def q(p):
        c=T[:,:3]@p+T[:,3]-org; return np.array([c.dot(der),c.dot(arr),c.dot(fre)])/k
    def nec(p,r): return necesidad(q(p),r)*k
    r0=np.linalg.norm(delta)
    rr0=min(rmax,max(rmin,r0)); base=delta*(rr0/max(r0,1e-9))
    yb=base.dot(arriba); rTope=rmax-1e-3; H2=rTope*rTope-yb*yb
    hb=base-yb*arriba
    maxS=0.0 if H2<=0 else MAX_EMPUJE
    def objetivo(S):
        if S<=0: return delta
        hn=hb+frente*S; n=np.linalg.norm(hn); H=np.sqrt(H2)
        if n>H: hn=hn*(H/n)
        return yb*arriba+hn
    radios=[0.028]+[0.022 if i%4==0 else (0.004 if i%4==3 else 0.009) for i in range(20)]
    S=0.0; theta=0.0; it=0; cost=0.0
    for it in range(10):
        d=objetivo(S)
        elb,wri=ik(sh,d,codoDes,dirUp,rmin,rmax,0.0)
        pts=[wri]+[wri+mano_off[i] for i in range(20)]
        hneed=max(nec(p,r) for p,r in zip(pts,radios))
        if hneed>TOL:
            if S>=maxS-1e-9: break
            S=min(maxS,S+hneed); continue
        best=None
        for th in THETAS:
            elb,wri=ik(sh,d,codoDes,dirUp,rmin,rmax,th)
            arm=[(elb,0.038)]+[(elb+(wri-elb)*t,0.04-0.01*t) for t in (0.2,0.4,0.6,0.8)]
            c=max(nec(p,r) for p,r in arm)
            j=c*50+abs(th)*0.01
            if best is None or j<best[0]: best=(j,th,c)
        # refinar el giro por seccion aurea alrededor del mejor de la rejilla
        def jgiro(th):
            e_,w_=ik(sh,d,codoDes,dirUp,rmin,rmax,th)
            ar=[(e_,0.038)]+[(e_+(w_-e_)*t,0.04-0.01*t) for t in (0.2,0.4,0.6,0.8)]
            c_=max(nec(p,r) for p,r in ar)
            return c_*50+abs(th)*0.01,c_
        a_=max(-MAXG,best[1]-PASOG); b_=min(MAXG,best[1]+PASOG)
        gr=(np.sqrt(5)-1)/2
        x1=b_-gr*(b_-a_); x2=a_+gr*(b_-a_); f1=jgiro(x1); f2=jgiro(x2)
        for _ in range(8):
            if f1[0]<f2[0]:
                b_=x2; x2=x1; f2=f1; x1=b_-gr*(b_-a_); f1=jgiro(x1)
            else:
                a_=x1; x1=x2; f1=f2; x2=a_+gr*(b_-a_); f2=jgiro(x2)
        thr=(a_+b_)/2; fr=jgiro(thr)
        if fr[0]<best[0]: best=(fr[0],thr,fr[1])
        theta=best[1]; cost=best[2]
        if best[2]<TOL: break
        if S>=maxS-1e-9: break
        S=min(maxS,S+max(0.005,best[2]*0.5))
    giro_obj=theta
    if previo is not None:
        RATE=np.radians(12)
        theta=previo+max(-RATE,min(RATE,theta-previo))
    return dict(empuje=S,delta=objetivo(S),giro=theta,giroObjetivo=giro_obj,costo=cost,iter=it)
