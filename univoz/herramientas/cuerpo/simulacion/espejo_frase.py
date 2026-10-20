# Uso: python espejo_frase.py "hola, como estas?" ...   (PLANTILLAS=ruta opcional)
# Copia en Python de planificarFrase (frase_a_senas.dart) para probarla con el diccionario real.
import json, re, sys
import os
_ruta=os.environ.get('PLANTILLAS',os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','..','..','assets','plantillas.json'))
dic={}
for t in json.load(open(_ruta,encoding='utf-8'))['plantillas']: dic.setdefault(t['gloss'],t.get('espanol') or '')
CON='áàäâãéèëêíìïîóòöôõúùüûç'; SIN='aaaaaeeeeiiiiooooouuuuc'
def mse(s): return ''.join(SIN[CON.index(c)] if c in CON else c for c in s.lower())
def clave(p): return mse(p).replace('ñ','n')
RE=re.compile(r'[0-9a-zA-ZáàäâãéèëêíìïîóòöôõúùüûñçÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ]+')
def palabras(t): return RE.findall(t)
def letra(x): return x in ('LL','RR','NN') or (len(x)==1 and 'A'<=x<='Z')
OMIT={'el','la','los','las','lo','un','una','unos','unas','de','del','al','a','y','e','o','u'}
IRR={'quiero':'querer','quieres':'querer','quiere':'querer','quieren':'querer','puedo':'poder','puedes':'poder','puede':'poder','pueden':'poder','tengo':'tener','tienes':'tener','tiene':'tener','tienen':'tener','entiendo':'entender','entiendes':'entender','entiende':'entender','siento':'sentir','sientes':'sentir','siente':'sentir','vengo':'venir','vienes':'venir','viene':'venir','voy':'ir','vas':'ir','va':'ir','vamos':'ir','soy':'ser','eres':'ser','es':'ser','somos':'ser','son':'ser','estoy':'estar','estas':'estar','esta':'estar','estamos':'estar','estan':'estar','hago':'hacer','haces':'hacer','hace':'hacer','digo':'decir','dices':'decir','dice':'decir','se':'saber','sabes':'saber','sabe':'saber','conozco':'conocer','necesito':'necesitar','duele':'doler','duelen':'doler'}
TER=['amos','emos','imos','ando','iendo','ado','ada','ido','ida','as','es','an','en','o','a','e']
def variantes(c):
    out=[]
    def ag(v):
        if len(v)>=2 and v!=c and v not in out: out.append(v)
    if c in IRR: ag(IRR[c])
    if c.endswith('es') and len(c)>4: ag(c[:-2])
    if c.endswith('s') and len(c)>2: ag(c[:-1])
    if c.endswith('a') and len(c)>3: ag(c[:-1]+'o')
    if c.endswith('as') and len(c)>4: ag(c[:-2]+'o')
    for pr in ['me','te','nos','le','les','lo','la']:
        if c.endswith(pr) and len(c)-len(pr)>=4: ag(c[:-len(pr)])
    for t in TER:
        if c.endswith(t) and len(c)-len(t)>=3:
            r=c[:-len(t)]; ag(r+'ar'); ag(r+'er'); ag(r+'ir')
    return out
def plan(texto):
    idx={}; mx=1
    def ix(f,gl):
        nonlocal mx
        ps=[clave(p) for p in palabras(f)]
        if not ps: return
        idx.setdefault(' '.join(ps),gl); mx=max(mx,len(ps))
    gls=sorted(dic)
    for gl in gls:
        if not letra(gl) and dic[gl].strip(): ix(dic[gl],gl)
    for gl in gls:
        if not letra(gl): ix(gl.replace('_',' '),gl)
    ps=palabras(texto); cl=[clave(p) for p in ps]; out=[]; om=[]; sin=[]; i=0
    while i<len(ps):
        hit=None
        for l in range(min(mx,len(ps)-i),0,-1):
            k=' '.join(cl[i:i+l])
            if k in idx: hit=(idx[k],l); break
        if hit: out.append(hit[0]); i+=hit[1]; continue
        var=None
        for v in variantes(cl[i]):
            if v in idx: var=idx[v]; break
        if var: out.append(var); i+=1; continue
        if cl[i] in OMIT: om.append(ps[i]); i+=1; continue
        s=mse(ps[i]); k=0; let=[]
        while k<len(s):
            dos=s[k:k+2]
            if dos in ('ll','rr') and dos.upper() in dic: let.append(dos.upper()+'·'); k+=2; continue
            c=s[k]; gg='NN' if c=='ñ' else c.upper()
            if gg not in dic: let=None; break
            let.append(gg+'·'); k+=1
        if let is None: sin.append(ps[i])
        else: out.extend(let)
        i+=1
    return out,om,sin
for t in sys.argv[1:]: print(repr(t),'->',plan(t))
