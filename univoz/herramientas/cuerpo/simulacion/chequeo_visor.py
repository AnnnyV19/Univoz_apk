import json,sys,os,numpy as np
from multiprocessing import Pool
from simular import torso,hand_pts
casos=json.load(open(os.environ.get('CASOS_VISOR','../casos_visor.json')))['casos']
salida=json.load(open(sys.argv[1]))
STEP=int(sys.argv[2]) if len(sys.argv)>2 else 2
def a_archivo(pw): return np.array([-pw[0],pw[1],-pw[2]])
def reposo_archivo(pw,T):
    T=np.array(T).reshape(3,4); p=T[:,:3]@np.array(pw)+T[:,3]; return a_archivo(p)
def pen(codo,mun,mano,T):
    e=reposo_archivo(codo,T); w=reposo_archivo(mun,T)
    # mano: la forma de la plantilla, en el sistema archivo (z archivo = +p[2]); la inclinacion del pecho rota todo el brazo con T^-1: aproximamos
    # girando los desplazamientos de la mano por la parte de rotacion de T (mundo actual -> reposo)
    Rr=np.array(T).reshape(3,4)[:,:3]
    sh=np.array(mano)
    hp=hand_pts(w,sh.reshape(-1))  # en archivo, sin rotar
    # hand_pts ya esta en archivo; la rotacion T actua sobre el vector en mundo: rotar el desplazamiento en el mundo y volver a archivo
    off=hp-w   # archivo
    off_w=np.array([-off[:,0],off[:,1],-off[:,2]]).T   # mundo
    off_r=(Rr@off_w.T).T
    off_f=np.array([-off_r[:,0],off_r[:,1],-off_r[:,2]]).T
    hp=w+off_f
    ph=[(w,0.028)]+[(hp[i],0.022 if i%4==0 else (0.004 if i%4==3 else 0.009)) for i in range(20)]
    pa=[(e,0.038)]+[(e+(w-e)*t,0.04-0.01*t) for t in (0.25,0.5,0.75)]
    h=max(torso.depth(p)+r for p,r in ph); a=max(torso.depth(p)+r for p,r in pa)
    return h,a
def work(i):
    c=casos[i]; s=salida[i]
    # escala de la mano: igual que el visor (nudillo medio a la distancia de la palma)
    off=pen(s['off']['codo'],s['off']['muneca'],np.array(c['mano']).reshape(-1),s['T'])
    on=pen(s['on']['codo'],s['on']['muneca'],np.array(c['mano']).reshape(-1),s['T'])
    return (i,)+off+on
if __name__=='__main__':
    idx=list(range(0,len(casos),STEP))
    with Pool(2) as p: res=p.map(work,idx,chunksize=40)
    A=np.array(res)
    for nombre,j in (('mano/muñeca ANTES',1),('antebrazo/codo ANTES',2),('mano/muñeca DESPUES',3),('antebrazo/codo DESPUES',4)):
        v=A[:,j]; print('%-24s >0.5cm %5.1f%%  >1cm %5.1f%%  >2cm %5.1f%%  max %.3f'%(nombre,100*(v>0.005).mean(),100*(v>0.01).mean(),100*(v>0.02).mean(),v.max()))
    print('cuadros evaluados',len(A))
