import numpy as np
from simular import m, W, PALM
db=m.dom_bone()
H=m.pos['leftHand']; M=m.pos['leftMiddleProximal']; 
print('W',W,'PALM',PALM)
ax=(m.pos['leftMiddleDistal']-H); ax/=np.linalg.norm(ax)
print('eje mano (muneca->distal medio):',np.round(ax,3), 'long. muneca->distal medio', np.linalg.norm(m.pos['leftMiddleDistal']-H))
names=[k for k in m.pos if k.startswith('leftThumb') or k.startswith('leftIndex') or k.startswith('leftMiddle') or k.startswith('leftRing') or k.startswith('leftLittle') or k=='leftHand']
mask=np.isin(db,names)
V=m.verts[mask]-H
print('vertices de mano',mask.sum())
# marco de la mano: eje largo = ax; transversal en plano: PCA del resto
Vp=V-np.outer(V.dot(ax),ax)
u,s,vt=np.linalg.svd(Vp[:, :]-Vp.mean(0),full_matrices=False)
e1=vt[0]; e2=np.cross(ax,e1); 
print('extension largo %.4f..%.4f'%(V.dot(ax).min(),V.dot(ax).max()))
print('extension eje1 %.4f..%.4f (ancho)'%(V.dot(e1).min(),V.dot(e1).max()), ' eje2 %.4f..%.4f'%(V.dot(e2).min(),V.dot(e2).max()))
# palma: vertices dominados por leftHand
pm=db==  'leftHand'
Vh=m.verts[pm]-H
print('palma n',pm.sum(),'largo %.4f..%.4f  e1 %.4f..%.4f  e2 %.4f..%.4f'%(Vh.dot(ax).min(),Vh.dot(ax).max(),Vh.dot(e1).min(),Vh.dot(e1).max(),Vh.dot(e2).min(),Vh.dot(e2).max()))
# grosor por segmentos
def seg(a,b):
    P=m.pos[a]; Q=m.pos[b]; return P,Q
pairs=[('leftIndexProximal','leftIndexIntermediate'),('leftIndexIntermediate','leftIndexDistal'),('leftMiddleProximal','leftMiddleIntermediate'),('leftMiddleIntermediate','leftMiddleDistal'),('leftRingProximal','leftRingIntermediate'),('leftLittleProximal','leftLittleIntermediate')]
for a,b in pairs:
    if a not in m.pos or b not in m.pos: continue
    P,Q=seg(a,b); d=Q-P; L=np.linalg.norm(d); d/=L
    vm=db==a
    if vm.sum()==0: print(a,'sin vertices'); continue
    X=m.verts[vm]-P; t=X.dot(d); perp=np.linalg.norm(X-np.outer(t,d),axis=1)
    print('%-24s largo %.4f radio med %.4f p90 %.4f max %.4f'%(a,L,np.median(perp),np.percentile(perp,90),perp.max()))
# distal tips
for a in ['leftIndexDistal','leftMiddleDistal']:
    vm=db==a; P=m.pos[a]
    X=m.verts[vm]-P
    print(a,'n',vm.sum(),'extension: ',np.round(np.linalg.norm(X,axis=1).max(),4))
print('antebrazo: ')
P=m.pos['leftLowerArm']; Q=m.pos['leftHand']; d=Q-P; L=np.linalg.norm(d); d/=L
vm=db=='leftLowerArm'; X=m.verts[vm]-P; t=X.dot(d)/L; perp=np.linalg.norm(X-np.outer(X.dot(d),d),axis=1)
for lo,hi in ((0,.2),(.2,.4),(.4,.6),(.6,.8),(.8,1.0)):
    s=(t>=lo)&(t<hi)
    if s.sum(): print('  t %.1f-%.1f radio med %.4f p90 %.4f max %.4f'%(lo,hi,np.median(perp[s]),np.percentile(perp[s],90),perp[s].max()))
