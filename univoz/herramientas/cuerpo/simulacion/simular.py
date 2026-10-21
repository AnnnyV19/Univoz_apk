import numpy as np, json, sys
from torso import build
m,torso,head=build()
W=np.linalg.norm(m.pos['leftUpperArm']-m.pos['rightUpperArm'])
LU=np.linalg.norm(m.pos['leftLowerArm']-m.pos['leftUpperArm']); LL=np.linalg.norm(m.pos['leftHand']-m.pos['leftLowerArm'])
PALM=np.linalg.norm(m.pos['leftMiddleProximal']-m.pos['leftHand'])
SH={'L':m.pos['leftUpperArm'],'R':m.pos['rightUpperArm']}
IKMIN,IKMAX=0.05,2.60
def tpl2file(v):  # body-frame template vector (x right, y up, z front) -> file frame
    return np.array([v[0],v[1],-v[2]])
def radio_ang(a): return np.sqrt(max(0,LU*LU+LL*LL+2*LU*LL*np.cos(a)))
def ik(lado, d_wrist, d_elbow, gain=1.0):
    sh=SH[lado]
    delta=tpl2file(d_wrist)*W*gain
    tgt=sh+delta; r=np.linalg.norm(delta)
    rmin=max(abs(LU-LL)+1e-5, radio_ang(IKMAX)); rmax=min(LU+LL-1e-5, radio_ang(IKMIN))
    rr=min(rmax,max(rmin,r)); dirv=delta/max(r,1e-9)
    wrist=sh+dirv*rr
    ce=tpl2file(d_elbow)*W
    pl=ce-dirv*ce.dot(dirv)
    if np.dot(pl,pl)<1e-8: pl=np.array([0,-1.0,0])-dirv*(-dirv[1])
    if np.dot(pl,pl)<1e-8: pl=np.array([0,1.0,0])
    pl=pl-dirv*pl.dot(dirv); pl/=np.linalg.norm(pl)
    avance=(LU*LU-LL*LL+rr*rr)/(2*rr); alt=np.sqrt(max(0,LU*LU-avance*avance))
    elbow=sh+dirv*avance+pl*alt
    return elbow,wrist,tgt
def hand_pts(wrist, shape):
    sh=np.array(shape).reshape(20,3)
    s=PALM/np.linalg.norm(sh[8])
    return wrist+ s*np.stack([sh[:,0],sh[:,1],sh[:,2]],1)   # file z = +p[2]
PALMIDX=[0,4,8,12,16]   # thumb cmc, MCPs
TIPS=[3,7,11,15,19]
def analyze(seq):
    """returns dict of penetration depths (m, >0 means inside after adding radius) per frame for parts."""
    out=[]
    for f in seq:
        row={}
        body=f[0:24].reshape(8,3)
        for lado,(offLoc,offPres,offShape,iSh,iEl,iWr) in {'L':(24,30,32,0,2,4),'R':(27,31,92,1,3,5)}.items():
            if f[offPres]<0.5: continue
            sh=body[iSh]; el=body[iEl]
            if np.hypot(el[0],el[1])<=0.05: continue
            wr=f[offLoc:offLoc+3]
            elb,wri,tgt=ik(lado,wr-sh,el-sh)
            shp=SH[lado]
            pen={'wrist':[],'forearm':[],'upper':[],'elbow':[],'palm':[],'tips':[]}
            def P(solid,p,r): return solid.depth(p)+r
            for name,solid in (('t',torso),('h',head)):
                pen['wrist'].append((name,P(solid,wri,0.028)))
                pen['elbow'].append((name,P(solid,elb,0.035)))
                for t in (0.25,0.5,0.75):
                    pen['forearm'].append((name,P(solid,elb+(wri-elb)*t,0.03)))
                pen['upper'].append((name,P(solid,(shp+elb)/2,0.04)))
                hp=hand_pts(wri,f[offShape:offShape+60])
                for i in PALMIDX: pen['palm'].append((name,P(solid,hp[i],0.02)))
                for i in TIPS: pen['tips'].append((name,P(solid,hp[i],0.012)))
            for k,v in pen.items():
                for name in ('t','h'):
                    vals=[x for n,x in v if n==name]
                    row[(lado,k,name)]=max(vals)
        out.append(row)
    return out
if __name__=='__main__':
    print('W',W,'LU',LU,'LL',LL,'PALM',PALM)
    S=np.load('primeras.npz')
    import csv
    rows=[]
    for g in S.files:
        r=analyze(S[g])
        # aggregate: for each part & solid, over frames with hand: max penetration; fraction frames >0.01
        agg={}
        nh=0
        for row in r:
            if row: nh+=1
            for k,v in row.items():
                key=(k[1],k[2])
                a=agg.setdefault(key,[])
                a.append(v)
        rows.append((g,nh,agg))
    import pickle; pickle.dump(rows,open('rows.pkl','wb'))
    # summary
    def summ(part,solid,thr=0.01):
        res=[]
        for g,nh,agg in rows:
            a=agg.get((part,solid))
            if not a or nh==0: continue
            a=np.array(a); res.append((g,nh,a.max(),(a>thr).mean()))
        return res
    for part in ['wrist','forearm','palm','tips','elbow','upper']:
        for solid in ['t','h']:
            res=summ(part,solid)
            n=len(res); aff=sum(1 for r in res if r[3]>0.1)
            print(part,solid,'glosas con mano:',n,' con >10% de cuadros penetrando >1cm:',aff,' penetracion max global %.3f m'%max(r[2] for r in res))
