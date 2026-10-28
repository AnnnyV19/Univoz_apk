import sys,numpy as np,collections
exec(open('analizar.py').read().split('filas = []')[0].replace("run = np.load(sys.argv[1]); ent = np.load(sys.argv[2]); pref = sys.argv[3]","run=np.load(sys.argv[1]); ent=np.load(sys.argv[2])"))
J=['pul_CMC','pul_MCP','pul_IP','ind_MCP','ind_PIP','ind_DIP','med_MCP','med_PIP','med_DIP','anu_MCP','anu_PIP','anu_DIP','men_MCP','men_PIP','men_DIP']
errs=[];peores=collections.Counter();ej=[];signo=[]
for g in sorted({k.split('|')[0] for k in run.files if '|' in k}):
    A=run[g+'|alim'].astype(float); N=run[g+'|nodos'].astype(float); pos=run[g+'|pos']
    for lado,c in LADOS.items():
        k=np.where((A[:,c['pres']]>=0.5)&(pos>=10))[0]
        if len(k)<4: continue
        n0=c['n0']; Pav=N[k,n0+3:n0+23]-N[k,n0+2][:,None]; Pt=A[k,c['shape']:c['shape']+60].reshape(-1,20,3)@M_MANO.T
        e=(flexiones(Pav)-flexiones(Pt)).reshape(len(k),15); errs.append(e)
        big=np.abs(e)>60
        for j in np.where(big.any(0))[0]: peores[(g,lado)]+=int(big[:,j].sum())
E=np.concatenate(errs); AE=np.abs(E)
print('ticks',len(E))
for j,n in enumerate(J): print('%-8s med %5.1f p90 %5.1f p99 %5.1f  >30: %4.1f%%  >60: %4.2f%%  sesgo %5.1f'%(n,np.median(AE[:,j]),np.percentile(AE[:,j],90),np.percentile(AE[:,j],99),100*(AE[:,j]>30).mean(),100*(AE[:,j]>60).mean(),np.median(E[:,j])))
print('peores',peores.most_common(15))
