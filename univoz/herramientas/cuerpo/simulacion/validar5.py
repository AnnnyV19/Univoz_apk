import numpy as np, sys, pickle
from multiprocessing import Pool
from separar4 import *
from validar4 import S_,GL,entrada,DIRUP,rmin,rmax,hull_pen,MARCO,FRENTE,ARRIBA
SUB=4
def interp_seq(seq,lado):
    offPres,iEl={'L':(30,2),'R':(31,3)}[lado]
    ok=[(f[offPres]>=0.5 and np.hypot(*f[iEl*3:iEl*3+2])>0.05) for f in seq]
    runs=[];i=0
    while i<len(seq):
        if ok[i]:
            j=i
            while j+1<len(seq) and ok[j+1]: j+=1
            if j>i: runs.append((i,j))
            i=j+1
        else: i+=1
    out=[]
    for a,b in runs:
        fr=[]
        for k in range(a,b):
            for s in range(SUB):
                t=s/SUB; fr.append(seq[k]*(1-t)+seq[k+1]*t)
        fr.append(seq[b]); out.append(fr)
    return out
def work(g):
    seq=S_[g]; out=[]
    for lado in ('L','R'):
        for run in interp_seq(seq,lado):
            prev=None; prev_res=None
            for fi,f in enumerate(run):
                sh,delta,cod,mano_off,shape=entrada(lado,f)
                res=resolver(sh,delta,cod,DIRUP[lado],rmin,rmax,FRENTE,ARRIBA,mano_off,MARCO,previo=prev)
                prev=res['giro']
                e0,w0=ik(sh,delta,cod,DIRUP[lado],rmin,rmax,0.0)
                h0,a0=hull_pen(e0,w0,shape)
                e1,w1=ik(sh,res['delta'],cod,DIRUP[lado],rmin,rmax,res['giro'])
                h1,a1=hull_pen(e1,w1,shape)
                dth=0 if prev_res is None else abs(res['giro']-prev_res['giro'])
                dS=0 if prev_res is None else abs(res['empuje']-prev_res['empuje'])
                dW=0 if prev_res is None else np.linalg.norm(w1-prev_res['w1'])
                dW0=0 if prev_res is None else np.linalg.norm(w0-prev_res['w0'])
                prev_res=dict(giro=res['giro'],empuje=res['empuje'],w1=w1,w0=w0)
                out.append((g,lado,fi,h0,a0,h1,a1,np.degrees(dth),dS,dW,dW0,w0[1]-w1[1],np.degrees(res['giroObjetivo'])))
    return out
if __name__=='__main__':
    gl=GL[::3]
    with Pool(2) as p: res=p.map(work,gl,chunksize=4)
    rows=[r for x in res for r in x]
    pickle.dump(rows,open('validar5_rows.pkl','wb'))
    A=np.array([[r[3],r[4],r[5],r[6],r[7],r[8],r[9],r[10],r[11]] for r in rows])
    print('cuadros interpolados',len(A))
    for name,j in (('mano ANTES',0),('antebrazo ANTES',1),('mano DESPUES',2),('antebrazo DESPUES',3)):
        print('%-18s >0.5cm %5.1f%%  >1cm %5.1f%%  >2cm %5.1f%%  max %.3f'%(name,100*(A[:,j]>0.005).mean(),100*(A[:,j]>0.01).mean(),100*(A[:,j]>0.02).mean(),A[:,j].max()))
    print('max |dy| muñeca %.2e'%np.abs(A[:,8]).max())
    d=A[:,4]; print('salto de giro entre sub-cuadros: p50 %.2f° p99 %.1f° max %.1f° ; >12° (tasa): %.3f%%'%(*np.percentile(d,[50,99,100]),100*(d>12.001).mean()))
    dS=A[:,5]*100; print('salto del empuje entre sub-cuadros: p99 %.2f cm max %.2f cm'%(*np.percentile(dS,[99,100]),))
    dW=A[:,6]*100; dW0=A[:,7]*100
    ex=(dW-dW0); print('desplazamiento extra de la muñeca por sub-cuadro (con-sin separador): p99 %.2f cm max %.2f cm'%(*np.percentile(ex,[99,100]),))
