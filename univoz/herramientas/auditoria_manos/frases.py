import sys,time,numpy as np
from playwright.sync_api import sync_playwright
z=np.load(sys.argv[1] if len(sys.argv)>1 and sys.argv[1].endswith('.npz') else 'primeras.npz'); rng=np.random.default_rng(7)
gl=[g for g in z.files if len(g)>1]
frases=[list(rng.choice(gl,size=rng.integers(3,5),replace=False)) for _ in range(40)]
import os,threading,functools,http.server
WWW=os.path.join(os.path.dirname(os.path.abspath(__file__)),'www')
srv=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(type('H',(http.server.SimpleHTTPRequestHandler,),{'log_message':lambda *a:None}),directory=WWW))
threading.Thread(target=srv.serve_forever,daemon=True).start()
URL='http://127.0.0.1:%d/avatar_viewer/'%srv.server_address[1]
DT=1/60; L={'I':(0,30,6),'D':(23,31,9)}
for pag in [a for a in sys.argv[1:] if a.endswith('.html')] or ['auditoria.html']:
    with sync_playwright() as p:
        b=p.chromium.launch(args=['--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader']); pg=b.new_page()
        pg.goto(URL+pag+'?standalone=1')
        while not pg.evaluate('() => !!(window.__aud && window.__aud.listo())'): time.sleep(0.3)
        pg.evaluate('() => window.__aud.preparar()')
        V=[];Acc=[]
        for fr in frases:
            pg.evaluate('() => window.__aud.reposo(40)')
            segs=[{'frames':z[g].tolist(),'fps':30} for g in fr]
            r=pg.evaluate('([s]) => window.__aud.senar(null, 30, 40, s)',[segs])
            N=np.concatenate([np.array(r['nodos'],float).reshape(-1,46,3),np.array(r['post'],float).reshape(-1,46,3)])
            for n0 in (0,23):
                w=N[:,n0+2]; v=np.linalg.norm(np.diff(w,axis=0),axis=1)/DT; a=np.linalg.norm(np.diff(w,2,axis=0),axis=1)/DT**2
                V.append(v.max()); Acc.append(a.max())
        b.close()
    print(pag,'frases',len(frases),'| vel pico muñeca m/s p50 %.2f p90 %.2f max %.2f | acel pico m/s2 p50 %.0f p90 %.0f max %.0f'%(np.median(V),np.percentile(V,90),max(V),np.median(Acc),np.percentile(Acc,90),max(Acc)))
