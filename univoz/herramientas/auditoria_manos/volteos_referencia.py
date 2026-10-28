"""Prototipo: repara volteos de palma de pocos cuadros (fallo del detector).
Solo cambia el bloque de FORMA de la mano; nunca loc, cuerpo ni presencia.
Se parte del tramo mas largo sin volteos (confiable) y se camina hacia afuera:
un cuadro que gira de forma imposible respecto al ultimo bueno se marca malo;
si la racha mala es corta y despues vuelve un cuadro coherente, se rellena
interpolando; en los extremos se sostiene el ultimo bueno; si la racha es
larga se acepta como real."""
import numpy as np
UMBRAL = 60.0       # grados entre cuadros seguidos (30 fps) = 1800 grados/s: imposible
MAX_GLITCH = 6      # cuadros como maximo de una racha mala
COHERENTE = 60.0    # al volver: giro maximo respecto al ultimo bueno (+ margen por cuadro)
POR_CUADRO = 20.0
TOPE_VUELTA = 90.0  # nunca aceptar como "vuelta" algo mas girado que esto
LADOS = [(30, 32), (31, 92)]

def marco(p):
    u = p[8]; nu = np.linalg.norm(u)
    if nu < 1e-9: return None
    u = u / nu; s = p[4] - p[16]; s = s - u * (s @ u); ns = np.linalg.norm(s)
    if ns < 1e-9: return None
    s = s / ns
    return np.stack([u, s, np.cross(u, s)], 1)

def ang(a, b):
    return np.degrees(np.arccos(np.clip((np.trace(a.T @ b) - 1) / 2, -1, 1)))

def _corridas(seq, pres, sh):
    """listas de indices consecutivos con mano y forma valida"""
    out = []; cur = []
    for k in range(len(seq)):
        ok = seq[k, pres] >= 0.5 and marco(seq[k, sh:sh + 60].reshape(20, 3)) is not None
        if ok and (not cur or k == cur[-1] + 1): cur.append(k)
        else:
            if cur: out.append(cur)
            cur = [k] if ok else []
    if cur: out.append(cur)
    return out

def reparar(seq):
    out = seq.copy(); cambios = 0
    for pres, sh in LADOS:
        F = lambda k: out[k, sh:sh + 60].reshape(20, 3)
        for run in _corridas(seq, pres, sh):
            if len(run) < 3: continue
            R = [marco(F(k)) for k in run]
            # tramo mas largo sin volteos
            mejor = (0, 0); i0 = 0
            for i in range(1, len(run) + 1):
                if i == len(run) or ang(R[i - 1], R[i]) > UMBRAL:
                    if i - i0 > mejor[1] - mejor[0]: mejor = (i0, i)
                    i0 = i
            for paso, inicio, fin in ((1, mejor[1], len(run)), (-1, mejor[0] - 1, -1)):
                bueno = mejor[1] - 1 if paso == 1 else mejor[0]
                i = inicio
                while i != fin:
                    if ang(R[bueno], R[i]) <= UMBRAL:
                        bueno = i; i += paso; continue
                    # racha mala: buscar el siguiente cuadro coherente
                    j = i; vuelta = None
                    while j != fin and abs(j - i) < MAX_GLITCH:
                        j += paso
                        if j != fin and ang(R[bueno], R[j]) <= min(TOPE_VUELTA, COHERENTE + POR_CUADRO * abs(j - bueno)):
                            vuelta = j; break
                    if vuelta is not None:
                        a, b = run[bueno], run[vuelta]
                        for m in range(i, vuelta, paso):
                            k = run[m]; f = (k - a) / (b - a)
                            out[k, sh:sh + 60] = (1 - f) * seq[a, sh:sh + 60] + f * seq[b, sh:sh + 60]
                            R[m] = marco(F(k)); cambios += 1
                        bueno = vuelta; i = vuelta + paso
                    elif abs(fin - i) <= MAX_GLITCH and abs(fin - i) < abs(bueno - (mejor[0] if paso == 1 else mejor[1] - 1)) + 1:
                        # racha mala hasta el extremo, mas corta que lo bueno: sostener
                        for m in range(i, fin, paso):
                            out[run[m], sh:sh + 60] = out[run[bueno], sh:sh + 60]; R[m] = R[bueno]; cambios += 1
                        break
                    else:
                        bueno = i; i += paso  # racha larga: se acepta como real
    return out, cambios

def cuenta(s, umbral=120):
    c = 0
    for pres, sh in LADOS:
        for run in _corridas(s, pres, sh):
            R = [marco(s[k, sh:sh + 60].reshape(20, 3)) for k in run]
            c += sum(ang(R[i - 1], R[i]) > umbral for i in range(1, len(R)))
    return c

if __name__ == '__main__':
    import sys
    z = np.load(sys.argv[1]); antes = despues = tocadas = cuadros = 0
    for g in z.files:
        s = z[g]; r, n = reparar(s)
        antes += cuenta(s); despues += cuenta(r); tocadas += n > 0; cuadros += n
        keep = np.r_[0:32]
        assert np.array_equal(r[:, keep], s[:, keep]), g          # cuerpo, loc y presencia intactos
    print(sys.argv[1], '| volteos >120°: antes', antes, 'despues', despues, '| señas tocadas', tocadas, 'cuadros reparados', cuadros)
