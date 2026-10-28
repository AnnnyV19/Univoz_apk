# Ilustraciones planas de UNIVOZ (paleta de Lucía). viewBox 240x180.
M='#791FC1'; MO='#5B1493'; MC='#DCC8F5'; MT='#F3EDFA'; T='#29232F'; TS='#6E6679'
PINK='#E85DA0'; AMB='#F0B429'; BLUE='#5B8DEF'; SK1='#F2C9A0'; SK2='#B97A4E'; W='#FFFFFF'
def svg(body, bg=False):
    fondo = f'<circle cx="120" cy="92" r="82" fill="{MT}"/>' if bg else ''
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 180">{fondo}{body}</svg>'

def persona(x, y, piel, ropa, pelo=T, escala=1.0, mira=0):
    # cuerpo redondeado + cabeza + pelo; (x,y) = centro de la cabeza
    s=escala
    return (f'<g transform="translate({x},{y}) scale({s})">'
            f'<path d="M-34 86 Q-34 34 0 34 Q34 34 34 86 Z" fill="{ropa}"/>'
            f'<rect x="-9" y="18" width="18" height="20" rx="6" fill="{piel}"/>'
            f'<circle cx="0" cy="0" r="24" fill="{piel}"/>'
            f'<path d="M-24 -2 Q-26 -28 0 -28 Q26 -28 24 -2 Q14 -16 -4 -14 Q-16 -12 -24 -2 Z" fill="{pelo}"/>'
            f'<circle cx="{-8+mira}" cy="2" r="2.6" fill="{T}"/><circle cx="{8+mira}" cy="2" r="2.6" fill="{T}"/>'
            f'<path d="M{-6+mira} 11 Q{0+mira} 15 {6+mira} 11" stroke="{T}" stroke-width="2.4" fill="none" stroke-linecap="round"/>'
            '</g>')

def mano(x, y, piel, rot=0, s=1.0):
    # mano abierta: palma + 4 dedos + pulgar
    return (f'<g transform="translate({x},{y}) rotate({rot}) scale({s})">'
            f'<rect x="-13" y="-8" width="26" height="26" rx="10" fill="{piel}"/>'
            + ''.join(f'<rect x="{-13+i*7}" y="-30" width="6" height="26" rx="3" fill="{piel}"/>' for i in range(4)) +
            f'<rect x="10" y="-6" width="6" height="20" rx="3" fill="{piel}" transform="rotate(-35 13 4)"/>'
            '</g>')

def burbuja(x,y,w,h,color,cola='izq'):
    cx = x+18 if cola=='izq' else x+w-18
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{color}"/>'
            f'<path d="M{cx-8} {y+h-1} L{cx-2 if cola=="izq" else cx+2} {y+h+12} L{cx+8} {y+h-1} Z" fill="{color}"/>')

ilus = {}
# 1. Comunicarme: dos personas y una burbuja entre ellas
ilus['comunicarse'] = svg(
    persona(70, 92, SK1, M, mira=3) + persona(170, 92, SK2, PINK, mira=-3) +
    burbuja(92, 22, 56, 34, W) +
    ''.join(f'<circle cx="{106+i*14}" cy="39" r="4.5" fill="{M}"/>' for i in range(3)) +
    mano(118, 132, SK1, rot=-10, s=0.75))
# 2. Traducir una seña: teléfono con cámara viendo una mano -> texto
ilus['traducir'] = svg(
    f'<rect x="58" y="20" width="76" height="140" rx="14" fill="{T}"/>'
    f'<rect x="64" y="30" width="64" height="112" rx="8" fill="{MC}"/>'
    f'<circle cx="96" cy="25" r="2.5" fill="{TS}"/>' +
    mano(96, 98, SK2, rot=0, s=1.0) +
    f'<path d="M64 46 L64 36 L74 36 M118 36 L128 36 L128 46 M64 126 L64 136 L74 136 M118 136 L128 136 L128 126" stroke="{M}" stroke-width="3.5" fill="none" stroke-linecap="round"/>'
    f'<path d="M142 90 L162 90 M154 82 L162 90 L154 98" stroke="{M}" stroke-width="5" fill="none" stroke-linecap="round" stroke-linejoin="round"/>' +
    burbuja(166, 66, 58, 44, W, cola='izq') +
    f'<rect x="176" y="79" width="38" height="6" rx="3" fill="{M}"/><rect x="176" y="91" width="26" height="6" rx="3" fill="{MC}"/>')
# 3. Aprender LSM: avatar con la mano en alto junto a un pizarrón
ilus['aprender'] = svg(
    f'<rect x="118" y="34" width="96" height="70" rx="10" fill="{W}" stroke="{MC}" stroke-width="4"/>' +
    mano(146, 76, SK1, s=0.7) +
    f'<rect x="168" y="56" width="34" height="6" rx="3" fill="{M}"/><rect x="168" y="68" width="24" height="6" rx="3" fill="{MC}"/>'
    f'<rect x="162" y="104" width="6" height="40" rx="3" fill="{MC}"/>' +
    persona(78, 86, SK2, M, mira=3) + mano(116, 70, SK2, rot=12, s=0.8) +
    f'<path d="M97 126 L112 84" stroke="{SK2}" stroke-width="13" stroke-linecap="round"/>')
# 4. Ciego/a: lentes oscuros y bastón
ilus['ciego'] = svg(
    persona(110, 80, SK1, M) +
    f'<rect x="86" y="72" width="22" height="13" rx="5" fill="{T}"/><rect x="112" y="72" width="22" height="13" rx="5" fill="{T}"/>'
    f'<rect x="106" y="76" width="8" height="3" fill="{T}"/>'
    f'<path d="M146 112 L176 170" stroke="{W}" stroke-width="7" stroke-linecap="round"/>'
    f'<path d="M146 112 L176 170" stroke="{T}" stroke-width="7" stroke-linecap="round" stroke-dasharray="0 0 14 10"/>'
    f'<circle cx="144" cy="110" r="8" fill="{SK1}"/>')
# 5. Sordo/a: oreja tachada + mano
ilus['sordo'] = svg(
    f'<g transform="translate(-22,0)">'f'<path d="M96 40 C102 14 150 12 156 46 C160 68 146 80 138 92 C132 102 134 116 124 128 C112 142 88 136 90 118 C91 110 100 108 102 100 C96 92 90 66 96 40 Z" fill="{SK2}"/>'f'<path d="M110 52 C114 36 140 36 142 54 C143 66 132 70 128 80 C126 86 128 94 122 100" stroke="#8E5A35" stroke-width="7" fill="none" stroke-linecap="round"/>''</g>' +
    f'<path d="M70 132 L156 30" stroke="{PINK}" stroke-width="10" stroke-linecap="round"/>' +
    mano(184, 128, SK1, rot=10, s=0.85))
# 6. Mudo/a: boca tachada y el teléfono habla
ilus['mudo'] = svg(
    f'<path d="M58 84 Q84 64 110 84 Q84 108 58 84 Z" fill="{PINK}"/><path d="M60 84 L108 84" stroke="{MO}" stroke-width="3"/>'
    f'<path d="M52 112 L118 56" stroke="{T}" stroke-width="9" stroke-linecap="round"/>'
    f'<rect x="142" y="44" width="44" height="80" rx="9" fill="{T}"/><rect x="147" y="52" width="34" height="62" rx="5" fill="{MC}"/>'
    f'<path d="M156 76 L162 76 L170 68 L170 98 L162 90 L156 90 Z" fill="{M}"/>'
    f'<path d="M196 70 Q204 83 196 96 M206 62 Q218 83 206 104" stroke="{M}" stroke-width="5" fill="none" stroke-linecap="round"/>')
# 7. Prestaré mi celular: teléfono que pasa de una mano a otra
ilus['prestar'] = svg(
    f'<rect x="100" y="42" width="40" height="72" rx="8" fill="{T}"/><rect x="105" y="50" width="30" height="54" rx="4" fill="{MC}"/>' +
    mano(76, 118, SK1, rot=60, s=0.9) + mano(164, 118, SK2, rot=-60, s=0.9) +
    f'<path d="M84 34 Q120 8 156 34" stroke="{M}" stroke-width="5" fill="none" stroke-linecap="round"/>'
    f'<path d="M146 24 L156 34 L144 40" stroke="{M}" stroke-width="5" fill="none" stroke-linecap="round" stroke-linejoin="round"/>')
# 8. Oyente: oreja con ondas de sonido
ilus['oyente'] = svg(
    f'<g transform="translate(-34,0)">'f'<path d="M96 40 C102 14 150 12 156 46 C160 68 146 80 138 92 C132 102 134 116 124 128 C112 142 88 136 90 118 C91 110 100 108 102 100 C96 92 90 66 96 40 Z" fill="{SK1}"/>'f'<path d="M110 52 C114 36 140 36 142 54 C143 66 132 70 128 80 C126 86 128 94 122 100" stroke="#D9A57A" stroke-width="7" fill="none" stroke-linecap="round"/>''</g>' +
    f'<path d="M140 60 Q152 78 140 96 M154 48 Q174 78 154 108 M168 36 Q196 78 168 120" stroke="{M}" stroke-width="6" fill="none" stroke-linecap="round"/>')
# 9-10. Conoce LSM / no conoce LSM: mano con palomita o con tache
def palomita(cx, cy, r):
    return (f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{M}"/>'
            f'<path d="M{cx-r*0.45} {cy} L{cx-r*0.1} {cy+r*0.36} L{cx+r*0.48} {cy-r*0.34}" stroke="{W}" stroke-width="{r*0.28}" fill="none" stroke-linecap="round" stroke-linejoin="round"/>')
def tache(cx, cy, r):
    d = r*0.4
    return (f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{TS}"/>'
            f'<path d="M{cx-d} {cy-d} L{cx+d} {cy+d} M{cx+d} {cy-d} L{cx-d} {cy+d}" stroke="{W}" stroke-width="{r*0.26}" stroke-linecap="round"/>')
# Las letras L, S y M del abecedario de LSM, una mano por letra.
def mano_l(x, y, piel, s=1.0):
    # índice arriba y pulgar de lado: forma de L
    return (f'<g transform="translate({x},{y}) scale({s})">'
            f'<rect x="-14" y="-6" width="28" height="30" rx="10" fill="{piel}"/>'
            f'<rect x="-12" y="-40" width="8" height="38" rx="4" fill="{piel}"/>'
            f'<rect x="-34" y="-2" width="26" height="8" rx="4" fill="{piel}"/>'
            + ''.join(f'<rect x="{-3+i*7}" y="-12" width="7" height="12" rx="3.5" fill="{piel}"/>' for i in range(3)) +
            f'<path d="M-3 -2 L18 -2" stroke="#00000022" stroke-width="2"/>'
            '</g>')
def mano_s(x, y, piel, s=1.0):
    # puño con el pulgar cruzado al frente
    return (f'<g transform="translate({x},{y}) scale({s})">'
            f'<rect x="-17" y="-20" width="34" height="44" rx="12" fill="{piel}"/>'
            + ''.join(f'<path d="M{-17+i*8.5} -20 L{-17+i*8.5} -6" stroke="#00000026" stroke-width="2"/>' for i in range(1, 4)) +
            f'<rect x="-18" y="-6" width="30" height="10" rx="5" fill="{piel}" stroke="#00000022" stroke-width="1.5"/>'
            '</g>')
def mano_m(x, y, piel, s=1.0):
    # tres dedos hacia abajo sobre el pulgar
    return (f'<g transform="translate({x},{y}) scale({s})">'
            f'<rect x="-15" y="-26" width="30" height="28" rx="10" fill="{piel}"/>'
            + ''.join(f'<rect x="{-14+i*9.5}" y="-4" width="8" height="30" rx="4" fill="{piel}"/>' for i in range(3)) +
            f'<rect x="12" y="-14" width="7" height="18" rx="3.5" fill="{piel}" transform="rotate(25 15 -5)"/>'
            '</g>')
def letras_lsm(piel):
    return (mano_l(62, 92, piel, 1.05) + mano_s(120, 92, piel, 1.05) + mano_m(178, 92, piel, 1.05) +
            ''.join(f'<text x="{x}" y="158" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="26" font-weight="800" fill="{M}">{t}</text>'
                    for x, t in ((58, 'L'), (120, 'S'), (178, 'M'))))
def prohibido(cx, cy, r):
    return (f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="#DC2626" stroke-width="11"/>'
            f'<path d="M{cx-r*0.7} {cy-r*0.7} L{cx+r*0.7} {cy+r*0.7}" stroke="#DC2626" stroke-width="11" stroke-linecap="round"/>')
ilus['lsm_si'] = svg(letras_lsm(SK2))
ilus['lsm_no'] = svg(letras_lsm(SK1) + prohibido(120, 92, 78))
# 11-12. Usa lector de pantalla / no: teléfono que habla, o callado
def telefono(x, y):
    return (f'<rect x="{x}" y="{y}" width="64" height="120" rx="12" fill="{T}"/>'
            f'<rect x="{x+6}" y="{y+10}" width="52" height="100" rx="6" fill="{MC}"/>'
            f'<rect x="{x+14}" y="{y+30}" width="36" height="6" rx="3" fill="{M}"/>'
            f'<rect x="{x+14}" y="{y+42}" width="26" height="6" rx="3" fill="{W}"/>'
            f'<rect x="{x+14}" y="{y+54}" width="32" height="6" rx="3" fill="{W}"/>')
ilus['lector_si'] = svg(telefono(78, 30) +
    f'<path d="M154 74 Q164 90 154 106 M166 64 Q182 90 166 116" stroke="{M}" stroke-width="6" fill="none" stroke-linecap="round"/>' +
    palomita(80, 146, 20))
ilus['lector_no'] = svg(telefono(78, 30) +
    f'<path d="M154 78 L178 102 M178 78 L154 102" stroke="{TS}" stroke-width="6" stroke-linecap="round"/>' +
    tache(80, 146, 20))
# 13. Accesibilidad: corazón con una mano
ilus['accesibilidad'] = svg(
    f'<path d="M120 162 C60 124 46 88 62 64 C78 42 106 46 120 66 C134 46 162 42 178 64 C194 88 180 124 120 162 Z" fill="{M}"/>' +
    mano(120, 108, W, s=1.0))
# 14. Hablar: micrófono con ondas
ilus['hablar'] = svg(
    f'<rect x="98" y="26" width="44" height="78" rx="22" fill="{M}"/>'
    f'<path d="M82 86 Q82 128 120 128 Q158 128 158 86" stroke="{T}" stroke-width="7" fill="none" stroke-linecap="round"/>'
    f'<rect x="116" y="128" width="8" height="22" fill="{T}"/><rect x="96" y="148" width="48" height="8" rx="4" fill="{T}"/>'
    f'<path d="M172 54 Q184 70 172 86 M60 54 Q48 70 60 86" stroke="{MC}" stroke-width="6" fill="none" stroke-linecap="round"/>')
# 15. Escribir: teclado y texto
ilus['escribir'] = svg(
    burbuja(56, 24, 128, 50, MT) +
    f'<rect x="72" y="40" width="70" height="7" rx="3.5" fill="{M}"/><rect x="72" y="53" width="46" height="7" rx="3.5" fill="{MC}"/>'
    f'<rect x="52" y="96" width="136" height="64" rx="10" fill="{T}"/>' +
    ''.join(f'<rect x="{62+i*17}" y="{106+j*17}" width="13" height="12" rx="3" fill="{MC if (i+j)%3 else W}"/>' for j in range(3) for i in range(7)))
import os, sys
for k,v in ilus.items():
    open(os.path.join(os.path.dirname(os.path.abspath(__file__)), k+'.svg'),'w').write(v)
