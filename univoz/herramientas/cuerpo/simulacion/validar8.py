"""Secuencias interpoladas (como el visor): estado entre cuadros, saltos, tasa."""
import numpy as np, sys, pickle, os
from multiprocessing import Pool
import separar7
from separar7 import *
from validar4 import S_,GL,entrada,DIRUP,rmin,rmax,MARCO,FRENTE,ARRIBA,hull_pen
from validar7 import mk, pct
SUB=int(os.environ.get('SUB','4')); RATE=float(os.environ.get('RATE','0.02'))
def runs_par(seq):
    ok=[(f[30]>=0.5 and f[31]>=0.5 and np.hypot(*f[6:8])>0.05 and np.hypot(*f[9:11])>0.05) for f in seq]
    out=[];i=0
    while i<len(seq):
        if ok[i]:
            j=i
            while j+1<len(seq) and ok[j+1]: j+=1
            if j>i: out.append((i,j))
            i=j+1
        else: i+=1
    return out
def work(g):
    seq=S_[g]; out=[]
    for a,b in runs_par(seq):
        fr=[]
        for k in range(a,b):
            for s in range(SUB):
                t=s/SUB; fr.append(seq[k]*(1-t)+seq[k+1]*t)
        fr.append(seq[b])
        prevg={'L':None,'R':None}; prev_par=None; prevw=None; prevw0=None
        for fi,f in enumerate(fr):
            eL=mk('L',f); eR=mk('R',f); E={'L':eL,'R':eR}
            # referencia: solo cuerpo, con la misma tasa de giro
            r0={l:resolver(**E[l],previo=prevg[l]) for l in E}
            P0={l:puntos(E[l],r0[l]) for l in E}
            hh0=penetracion(P0['L'][0],P0['R'][0])
            res,P1,sh,psi,nps,lim=resolver_par(eL,eR,prevg['L'],prevg['R'],prev_par,rate=RATE)
            for l in E: prevg[l]=res[l]['giro']
            prev_par={'psi':psi,'sh':sh}
            hh1=penetracion(P1['L'][0],P1['R'][0]); ha1=penetracion(P1['L'][0]+P1['L'][1],P1['R'][0]+P1['R'][1])
            w1={l:P1[l][2] for l in E}; w0={l:P0[l][2] for l in E}
            corr={l:w1[l]-w0[l] for l in E}     # correccion total (cuerpo+mano) respecto al IK crudo no la tenemos; usamos respecto al solo-cuerpo
            dcorr=0.0 if prevw is None else max(np.linalg.norm(corr[l]-prevw[l]) for l in E)
            dmove=0.0 if prevw0 is None else max(np.linalg.norm(w1[l]-prevw0[l]) for l in E)
            prevw=corr; prevw0=w1
            dy=max(abs(w1[l][1]-w0[l][1]) for l in E)
            tor=0.0
            for l in E:
                elb,wri=ik(E[l]['sh'],res[l]['delta'],E[l]['codoDes'],E[l]['dirUp'],E[l]['rmin'],E[l]['rmax'],res[l]['giro'])
                shape=entrada(l,f)[4]; tor=max(tor,*hull_pen(elb,wri,shape))
            out.append((g,fi,hh0,hh1,ha1,dcorr,dy,max(np.linalg.norm(sh['L']),np.linalg.norm(sh['R'])),float(lim),nps,tor))
    return out
if __name__=='__main__':
    gl=GL[::int(os.environ.get('GSTEP','2'))]
    with Pool(2) as p: res=p.map(work,gl,chunksize=4)
    rows=[r for x in res for r in x]
    A=np.array([r[2:] for r in rows])
    print('cuadros interpolados con dos manos',len(A),'SUB',SUB,'RATE',RATE,'MAX_SH',separar7.MAX_SH,'LAMBDA',separar7.LAMBDA)
    print('mano-mano ANTES   ',pct(A[:,0])); print('mano-mano DESPUES ',pct(A[:,1])); print('mano+antebrazo DESPUES',pct(A[:,2]))
    d=A[:,3]*100; print('salto de la correccion mano-mano entre sub-cuadros: p50 %.2f cm p99 %.2f cm max %.2f cm ; >2cm: %.2f%%'%(*np.percentile(d,[50,99,100]),100*(d>2).mean()))
    print('max |dy| muñeca (con-sin mano-mano): %.2e'%A[:,4].max())
    print('mano/antebrazo dentro del torso (casco de la malla) DESPUES:',pct(A[:,8]))
    print('desplazamiento por mano: p90 %.3f max %.3f ; sub-cuadros limitados por tasa: %.2f%%'%(*np.percentile(A[:,5],[90,100]),100*A[:,6].mean()))
