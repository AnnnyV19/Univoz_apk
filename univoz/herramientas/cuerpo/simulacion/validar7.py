import numpy as np, sys, pickle, os
from multiprocessing import Pool
from separar7 import *
from validar4 import S_,GL,entrada,DIRUP,rmin,rmax,MARCO,FRENTE,ARRIBA
STEP=int(os.environ.get('STEP','3'))
def mk(lado,f):
    sh,delta,cod,mano_off,shape=entrada(lado,f)
    return dict(sh=sh,delta=delta,codoDes=cod,dirUp=DIRUP[lado],rmin=rmin,rmax=rmax,frente=FRENTE,arriba=ARRIBA,mano_off=mano_off,marco=MARCO)
def work(g):
    seq=S_[g]; out=[]
    for fi in range(0,len(seq),STEP):
        f=seq[fi]
        if f[30]<0.5 or f[31]<0.5: continue
        if np.hypot(*f[6:8])<=0.05 or np.hypot(*f[9:11])<=0.05: continue
        eL=mk('L',f); eR=mk('R',f); E={'L':eL,'R':eR}
        r0={l:resolver(**E[l]) for l in E}
        P0={l:puntos(E[l],r0[l]) for l in E}
        hh0=penetracion(P0['L'][0],P0['R'][0]); ha0=penetracion(P0['L'][0]+P0['L'][1],P0['R'][0]+P0['R'][1])
        res,P1,sh,psi,nps,lim=resolver_par(eL,eR)
        hh1=penetracion(P1['L'][0],P1['R'][0]); ha1=penetracion(P1['L'][0]+P1['L'][1],P1['R'][0]+P1['R'][1])
        # altura vs sin separador alguno
        dy=max(abs(P1[l][2][1]-ik(E[l]['sh'],E[l]['delta'],E[l]['codoDes'],E[l]['dirUp'],E[l]['rmin'],E[l]['rmax'],0.0)[1][1]) for l in E)
        # contra el cuerpo: penetracion residual de muñeca/mano vs torso se mide en validar4; aqui solo empuje
        out.append((g,fi,hh0,ha0,hh1,ha1,max(np.linalg.norm(sh['L']),np.linalg.norm(sh['R'])),dy,nps,res['L']['empuje'],res['R']['empuje'],r0['L']['empuje'],r0['R']['empuje']))
    return out
def pct(v): return '>0.5cm %5.1f%% >1cm %5.1f%% >2cm %5.1f%% max %.3f'%(100*(v>0.005).mean(),100*(v>0.01).mean(),100*(v>0.02).mean(),v.max())
if __name__=='__main__':
    with Pool(2) as p: res=p.map(work,GL,chunksize=8)
    rows=[r for x in res for r in x]
    tag=os.environ.get('TAG','v7')
    pickle.dump(rows,open('validar7_%s.pkl'%tag,'wb'))
    A=np.array([r[2:] for r in rows])
    print('cuadros con dos manos',len(A),'STEP',STEP,'MAX_SH',MAX_SH,'LAMBDA',LAMBDA)
    for nombre,j in (('mano-mano ANTES',0),('mano+antebrazo ANTES',1),('mano-mano DESPUES',2),('mano+antebrazo DESPUES',3)):
        print('%-26s'%nombre,pct(A[:,j]))
    S=A[:,4]; print('desplazamiento por mano: >0.5cm %.1f%% p50(en los que mueven) %.3f p90 %.3f p99 %.3f max %.3f'%(100*(S>0.005).mean(),*np.percentile(S[S>0.005],[50,90,99,100])))
    print('max cambio de altura de muñeca: %.2e'%A[:,5].max())
    print('pases: media %.2f max %d'%(A[:,6].mean(),A[:,6].max()))
    E1=np.maximum(A[:,7],A[:,8]); E0=np.maximum(A[:,9],A[:,10])
    print('empuje de cuerpo (max de las dos manos): antes >0.5cm %.1f%%  despues %.1f%%; dif max %.3f'%(100*(E0>0.005).mean(),100*(E1>0.005).mean(),(E1-E0).max()))
