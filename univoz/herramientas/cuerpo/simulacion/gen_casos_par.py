import numpy as np, json
from separar7 import *
from validar4 import S_,GL,entrada,DIRUP,rmin,rmax
from simular import LU,LL,SH
rng=np.random.default_rng(11)
def rotmat(axis,ang):
    axis=axis/np.linalg.norm(axis); K=np.array([[0,-axis[2],axis[1]],[axis[2],0,-axis[0]],[-axis[1],axis[0],0]])
    return np.eye(3)+np.sin(ang)*K+(1-np.cos(ang))*K@K
ysh=SH['L'][1]; zs=SH['L'][2]
pool=[]
for g in GL:
    seq=S_[g]
    for fi in range(0,len(seq),2):
        f=seq[fi]
        if f[30]<0.5 or f[31]<0.5: continue
        if np.hypot(*f[6:8])<=0.05 or np.hypot(*f[9:11])<=0.05: continue
        pool.append((g,fi,f))
# priorizar cuadros con traslape: muestreo mitad con traslape
from validar7 import mk
con=[];sin=[]
for g,fi,f in pool:
    eL=mk('L',f); eR=mk('R',f)
    r={l:resolver(**e) for l,e in (('L',eL),('R',eR))}
    P={l:puntos(e,r[l]) for l,e in (('L',eL),('R',eR))}
    (con if penetracion(P['L'][0]+P['L'][1],P['R'][0]+P['R'][1])>0 else sin).append((g,fi,f))
print('con traslape',len(con),'sin',len(sin))
idx_c=rng.choice(len(con),min(120,len(con)),replace=False); idx_s=rng.choice(len(sin),30,replace=False)
sel=[con[i] for i in idx_c]+[sin[i] for i in idx_s]
casos=[]
def js(e):
    return dict(hombro=e['sh'].tolist(),delta=e['delta'].tolist(),codoDeseado=e['codoDes'].tolist(),dirUp=e['dirUp'].tolist(),lenUp=float(LU),lenLo=float(LL),
        radioMin=float(e['rmin']),radioMax=float(e['rmax']),frente=e['frente'].tolist(),arriba=e['arriba'].tolist(),mano=e['mano_off'].tolist(),
        marco=dict(T=e['marco']['T'].reshape(-1).tolist(),origen=e['marco']['origen'].tolist(),der=e['marco']['der'].tolist(),arr=e['marco']['arr'].tolist(),fre=e['marco']['fre'].tolist(),escala=float(e['marco']['escala'])))
for n,(g,fi,f) in enumerate(sel):
    eL=mk('L',f); eR=mk('R',f)
    k=1.0; T=np.hstack([np.eye(3),np.zeros((3,1))])
    modo=n%4
    if modo>=1:
        k=rng.uniform(0.85,1.25)
        Rm=rotmat(rng.normal(size=3),np.radians(rng.uniform(0,8)))
        piv=np.array([0,ysh-0.1,zs]); t=piv-Rm@piv+rng.normal(scale=0.003,size=3)
        T=np.hstack([Rm,t[:,None]])
    marco=dict(escala=k,T=T,origen=np.array([0,ysh,zs]),der=np.array([1.0,0,0]),arr=np.array([0,1.0,0]),fre=np.array([0,0,-1.0]))
    eL['marco']=marco; eR['marco']=marco
    prev=(None,None); pp=None
    if modo>=2:
        prev=(float(np.radians(rng.uniform(-50,50))),float(np.radians(rng.uniform(-50,50))))
        pp=dict(psi=float(rng.uniform(0,2*np.pi)),sh=[(rng.normal(scale=0.012,size=3)*np.array([1,0,1])).tolist() for _ in range(2)])
        pp_py=dict(psi=pp['psi'],sh={'L':np.array(pp['sh'][0]),'R':np.array(pp['sh'][1])})
    else: pp_py=None
    res,P,sh,psi,nps,lim=resolver_par(eL,eR,prev[0],prev[1],pp_py)
    casos.append(dict(es=[js(eL),js(eR)],previos=None if prev[0] is None else list(prev),prevPar=pp,
        out=dict(delta=[res['L']['delta'].tolist(),res['R']['delta'].tolist()],giro=[res['L']['giro'],res['R']['giro']],
                 empuje=[res['L']['empuje'],res['R']['empuje']],sh=[sh['L'].tolist(),sh['R'].tolist()],psi=psi,limitado=bool(lim),pases=nps)))
json.dump(casos,open('../casos_par.json','w'))
print(len(casos),'casos; con pases>0:',sum(c['out']['pases']>0 for c in casos),'; limitados:',sum(c['out']['limitado'] for c in casos))
