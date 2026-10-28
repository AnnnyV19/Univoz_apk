import sys, json, numpy as np
exec(open('analizar.py').read().split('filas = []')[0].replace("run = np.load(sys.argv[1]); ent = np.load(sys.argv[2]); pref = sys.argv[3]","run=np.load(sys.argv[1]); ent=np.load(sys.argv[2])"))
bins=np.arange(0,33,2); acc={k:[[] for _ in bins] for k in ['mun','muny','palma','flex','dmun','dpal','dflex']}
ent_pres=0
for g in sorted({k.split('|')[0] for k in run.files if '|' in k}):
    pos=run[g+'|pos'].astype(float); A=run[g+'|alim'].astype(float); N=run[g+'|nodos'].astype(float)
    O=interp(ent[g],pos)
    for lado,c in LADOS.items():
        pres=(A[:,c['pres']]>=0.5)&(np.hypot(A[:,c['el']],A[:,c['el']+1])>0.05)
        k=np.where(pres)[0]
        if len(k)<4: continue
        n0=c['n0']; hom=N[k,n0]; mun=N[k,n0+2]; Pav=N[k,n0+3:n0+23]-mun[:,None]
        obj=hom+((A[k,c['loc']:c['loc']+3]-A[k,c['sh']:c['sh']+3])@M_CUERPO.T)*ANCHO
        Pt=A[k,c['shape']:c['shape']+60].reshape(-1,20,3)@M_MANO.T
        em=np.linalg.norm(mun-obj,axis=1)*100; ey=(mun-obj)[:,1]*100
        Ra,Rt=marco_palma(Pav),marco_palma(Pt); ep=rot_ang(Ra,Rt); ef=np.abs(flexiones(Pav)-flexiones(Pt)).max(axis=(1,2))
        cons=np.r_[False,np.diff(k)==1]
        dm=np.r_[0,np.linalg.norm(np.diff(mun,axis=0),axis=1)*100-np.linalg.norm(np.diff(obj,axis=0),axis=1)*100]
        dp=np.r_[0,rot_ang(Ra[:-1],Ra[1:])-rot_ang(Rt[:-1],Rt[1:])]
        fa=flexiones(Pav); ft=flexiones(Pt)
        dfl=np.r_[0,np.abs(np.diff(fa,axis=0)).max(axis=(1,2))-np.abs(np.diff(ft,axis=0)).max(axis=(1,2))]
        b=np.digitize(pos[k],bins)-1
        for i in range(len(k)):
            acc['mun'][b[i]].append(em[i]); acc['muny'][b[i]].append(abs(ey[i])); acc['palma'][b[i]].append(ep[i]); acc['flex'][b[i]].append(ef[i])
            if cons[i]: acc['dmun'][b[i]].append(dm[i]); acc['dpal'][b[i]].append(dp[i]); acc['dflex'][b[i]].append(dfl[i])
print('pos   ' + ' '.join('%6d'%x for x in bins))
for kk,v in acc.items():
    print('%-5s p50 '%kk+' '.join('%6.1f'%(np.median(x) if x else 0) for x in v))
    print('%-5s p95 '%kk+' '.join('%6.1f'%(np.percentile(x,95) if x else 0) for x in v))
