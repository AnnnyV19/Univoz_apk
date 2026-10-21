import numpy as np, json
from separar4 import *
from validar4 import S_,GL,entrada,DIRUP,rmin,rmax,hull_pen
rng=np.random.default_rng(7)
def rotmat(axis,ang):
    axis=axis/np.linalg.norm(axis); K=np.array([[0,-axis[2],axis[1]],[axis[2],0,-axis[0]],[-axis[1],axis[0],0]])
    return np.eye(3)+np.sin(ang)*K+(1-np.cos(ang))*K@K
ysh=SH['L'][1]; zs=SH['L'][2]
casos=[]
pool=[]
for g in GL:
    seq=S_[g]
    for fi in range(0,len(seq),3):
        f=seq[fi]
        for lado,(offPres,iEl) in {'L':(30,2),'R':(31,3)}.items():
            if f[offPres]<0.5 or np.hypot(*f[iEl*3:iEl*3+2])<=0.05: continue
            pool.append((g,fi,lado,f))
idx=rng.choice(len(pool),400,replace=False)
for n,i in enumerate(idx):
    g,fi,lado,f=pool[i]
    sh,delta,cod,mano_off,shape=entrada(lado,f)
    frente=np.array([0,0,-1.0]); arriba=np.array([0,1.0,0]); dirup=DIRUP[lado]
    der=np.array([1.0,0,0]); arr=np.array([0,1.0,0]); fre=np.array([0,0,-1.0])
    k=1.0; T=np.hstack([np.eye(3),np.zeros((3,1))]); org=np.array([0,ysh,zs])
    modo=n%4
    previo=None
    if modo>=1:   # escala distinta y torso inclinado (T no identidad): el pecho "gira" respecto al mundo
        k=rng.uniform(0.8,1.3)
        Rm=rotmat(rng.normal(size=3),np.radians(rng.uniform(0,9)))
        piv=np.array([0,ysh-0.1,zs]); t=piv-Rm@piv+rng.normal(scale=0.003,size=3)
        T=np.hstack([Rm,t[:,None]])   # p_rest = R p + t
    if modo>=2: previo=float(np.radians(rng.uniform(-60,60)))
    # escalar el mundo por k alrededor del origen del hombro para ser consistente con la escala
    # (la tabla escala con k, las entradas ya son del mundo): solo se prueba que JS==Python
    marco=dict(escala=k,T=T,origen=org*1.0,der=der,arr=arr,fre=fre)
    res=resolver(sh,delta,cod,dirup,rmin,rmax,frente,arriba,mano_off,marco,previo=previo)
    casos.append(dict(
        e=dict(hombro=sh.tolist(),delta=delta.tolist(),codoDeseado=cod.tolist(),dirUp=dirup.tolist(),lenUp=float(LU),lenLo=float(LL),
               radioMin=float(rmin),radioMax=float(rmax),frente=frente.tolist(),arriba=arriba.tolist(),mano=mano_off.tolist(),
               marco=dict(T=T.reshape(-1).tolist(),origen=org.tolist(),der=der.tolist(),arr=arr.tolist(),fre=fre.tolist(),escala=k)),
        previo=previo,
        out=dict(empuje=res['empuje'],delta=res['delta'].tolist(),giro=res['giro'],giroObjetivo=res['giroObjetivo'],costo=res['costo'],iter=res['iter'])))
json.dump(casos,open('../../../../senas_core/tools/rig-tests/paridad_cuerpo/casos_cuerpo.json','w'))
print(len(casos),'casos; con empuje>0:',sum(c['out']['empuje']>0 for c in casos),'; con giro != 0:',sum(abs(c['out']['giroObjetivo'])>0 for c in casos))
