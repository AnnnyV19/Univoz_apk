"""Referencia Python v7: separacion cuerpo + mano contra mano (par de brazos), alturas intactas.
Mano contra mano: traslacion RELATIVA horizontal minima (metrica anisotropica: la profundidad cuesta menos que el costado),
repartida entre las dos munecas; cada paso vuelve a pasar por el separador de cuerpo."""
import numpy as np, os
from separar4 import *
MARGEN_HH=0.001; TOL_HH=0.0004
MAX_SH=float(os.environ.get('MAX_SH','0.045'))      # tope del desplazamiento horizontal por mano
LAMBDA=float(os.environ.get('LAMBDA','1.5'))        # costo del costado respecto a la profundidad
LEJOS=0.12; NPSI=48; KAPPA=float(os.environ.get('KAPPA','0.8')); PASES=6
RADH=[0.022]+[0.014 if i%4==0 else (0.006 if i%4==3 else 0.008) for i in range(20)]
def radio_ant(t): return 0.044-0.027*t
def cap_horizontal(d,arriba,rmax,rmin=0.0):
    rT=rmax-1e-3; y=d.dot(arriba); h=d-y*arriba; nh=np.linalg.norm(h); n=np.linalg.norm(d)
    if n>rT:
        H2=rT*rT-y*y
        if H2>0 and nh>1e-9: return y*arriba+h*(np.sqrt(H2)/nh)
    elif n<rmin:
        H2=rmin*rmin-y*y
        if H2>0 and nh>1e-9: return y*arriba+h*(np.sqrt(H2)/nh)
    return d
def puntos(e,res,k=1.0):
    elb,wri=ik(e['sh'],res['delta'],e['codoDes'],e['dirUp'],e['rmin'],e['rmax'],res['giro'])
    mano=[(wri,RADH[0]*k)]+[(wri+e['mano_off'][i],RADH[i+1]*k) for i in range(20)]
    ant=[(elb+(wri-elb)*t,radio_ant(t)*k) for t in (0.2,0.4,0.6,0.8)]+[(elb,0.040*k)]
    return mano,ant,wri
def penetracion(A,B,margen=None):
    margen=MARGEN_HH if margen is None else margen
    pen=-1e9
    for pa,ra in A:
        for pb,rb in B:
            pen=max(pen,ra+rb+margen-np.linalg.norm(pa-pb))
    return pen
def restricciones(A,B,arriba,margen=None,k=1.0):
    margen=MARGEN_HH if margen is None else margen
    """discos (hx,hz,Rh) en el plano horizontal: la traslacion relativa T de A respecto a B debe cumplir |h+T|>=Rh."""
    out=[]
    for pa,ra in A:
        for pb,rb in B:
            v=pa-pb; R=ra+rb+margen; dy=v.dot(arriba)
            if abs(dy)<R:
                Rh=np.sqrt(R*R-dy*dy); h=v-dy*arriba
                if np.linalg.norm(h)-Rh<LEJOS*k: out.append((h,Rh))
    return out
def mejor_T(cons,base_x,base_z,psi_prev=None):
    """cons: lista (h(3d),Rh). base_x, base_z: ejes horizontales (lateral, profundidad). Devuelve (T 3d, psi, costo)."""
    if not cons: return np.zeros(3),None,0.0
    H=np.array([[h.dot(base_x),h.dot(base_z)] for h,_ in cons]); Rh=np.array([r for _,r in cons])
    h2=(H**2).sum(1)
    best=None
    for ip in range(NPSI):
        psi=2*np.pi*ip/NPSI; n=np.array([np.cos(psi),np.sin(psi)])
        hn=H@n; disc=hn*hn-h2+Rh*Rh
        iv=[(-hn[j]-np.sqrt(disc[j]),-hn[j]+np.sqrt(disc[j])) for j in range(len(Rh)) if disc[j]>0]
        iv=[(a,b) for a,b in iv if b>0]
        iv.sort(); cur=0.0
        for a,b in iv:
            if a<cur-1e-12 or (cur==0.0 and a<=0.0): cur=max(cur,b)
            else: break
        t=cur+1e-4 if cur>0 else 0.0
        g=np.sqrt(LAMBDA*n[0]**2+n[1]**2)
        c=t*g
        if psi_prev is not None: c*=1+KAPPA*(1-np.cos(psi-psi_prev))/2
        if best is None or c<best[0]: best=(c,psi,t)
    c,psi,t=best
    return (np.cos(psi)*t)*base_x+(np.sin(psi)*t)*base_z,psi,t
def resolver_par(eL,eR,prevL=None,prevR=None,prev_par=None,con_antebrazo=True,k=None,rate=0.01):
    e={'L':eL,'R':eR}; prev={'L':prevL,'R':prevR}
    if k is None: k=eL['marco']['escala']
    margen=MARGEN_HH*k; tol=TOL_HH*k; maxsh=MAX_SH*k; tasa=(rate*k if rate else None)
    arriba=eL['arriba']; fr=eL['frente']; der=np.cross(arriba,fr)   # eje lateral (cualquier signo)
    der/=np.linalg.norm(der)
    base0={}
    for l in e:
        d=e[l]['delta']; r0=np.linalg.norm(d); rr0=min(e[l]['rmax'],max(e[l]['rmin'],r0)); base0[l]=d*(rr0/max(r0,1e-9))
    sh={'L':np.zeros(3),'R':np.zeros(3)}; w={'L':0.5,'R':0.5}; bloq={'L':False,'R':False}
    psi_prev=prev_par['psi'] if prev_par else None
    res={}; P={}; ew={}
    def correr(l):
        d=base0[l]+sh[l] if np.any(sh[l]) else e[l]['delta']
        if np.any(sh[l]): d=cap_horizontal(d,arriba,e[l]['rmax'],e[l]['rmin'])
        ee=dict(e[l]); ee['delta']=d; ew[l]=ee
        res[l]=resolver(**ee,previo=prev[l]); P[l]=puntos(ee,res[l],k)
    for l in e: correr(l)
    psi=psi_prev; T=np.zeros(3); wr_prev={l:P[l][2].copy() for l in e}; nps=0
    for it in range(PASES):
        A=P['L'][0]+(P['L'][1] if con_antebrazo else []); B=P['R'][0]+(P['R'][1] if con_antebrazo else [])
        if penetracion(A,B,margen)<=tol: break
        cons=restricciones(A,B,arriba,margen,k)
        T,psi_n,t=mejor_T(cons,der,fr,psi)
        if t<=1e-6: break
        psi=psi_n; nps+=1
        # T = traslacion de L respecto a R. Reparto segun peso.
        # profundidad: se mueve HACIA ADELANTE la mano que queda delante (atras esta el torso); costado: repartido
        Tx=T.dot(der); Tz=T.dot(fr)
        pl=w['L']*Tx*der; pr=-w['R']*Tx*der
        if Tz>=0:
            if not bloq['L']: pl=pl+Tz*fr
            else: pr=pr-Tz*fr
        else:
            if not bloq['R']: pr=pr+(-Tz)*fr
            else: pl=pl+Tz*fr
        sh['L']=sh['L']+pl; sh['R']=sh['R']+pr
        for l in e:
            n=np.linalg.norm(sh[l])
            if n>maxsh: sh[l]=sh[l]*(maxsh/n)
        wr0={l:P[l][2].copy() for l in e}
        for l in e: correr(l)
        # cuanto logro cada muñeca de lo pedido (proyeccion horizontal)
        for l,pl_ in (('L',pl),('R',pr)):
            dw=P[l][2]-wr0[l]; dw=dw-dw.dot(arriba)*arriba
            plan=np.linalg.norm(pl_)
            if plan>1e-4:
                ach=dw.dot(pl_)/plan/plan
                if ach<0.6:
                    bloq[l]=True; w[l]=max(0.1,w[l]*0.4)
        s_=w['L']+w['R']; w['L']/=s_; w['R']/=s_
        if max(np.linalg.norm(P[l][2]-wr0[l]) for l in e)<1e-4*k: break   # ya no avanza
    limitado=False
    if prev_par is not None and tasa:
        for l in e:
            d=sh[l]-prev_par['sh'][l]; n=np.linalg.norm(d)
            if n>tasa: sh[l]=prev_par['sh'][l]+d*(tasa/n); limitado=True
        if limitado:
            for l in e: correr(l)
    return res,P,sh,psi,nps,limitado
