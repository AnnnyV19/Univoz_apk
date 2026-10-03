"""Esqueletos sinteticos para pruebas y golden de sign_space/body_profile."""

import math

import sign_space as ss


def esqueleto(ancho=0.36, brazo=0.30, antebrazo=0.26, cuello=0.22,
              palma=(0.0, -0.10, 0.12), lado_palma="R",
              codo_r=None, giro=0.0, mover=(0.0, 0.0, 0.0), escala=1.0,
              caderas=True):
    """Esqueleto METRICO sintetico mirando a camara (ejes MediaPipe world:
    X a la derecha de la imagen, Y abajo, Z se aleja de la camara).

    El hombro IZQUIERDO de la persona cae en +X. [palma] es el destino de
    la palma derecha relativo al centro de hombros, en metros y en ejes de
    la PERSONA (+x su derecha, +y arriba, +z al frente). El brazo izquierdo
    cuelga.
    """
    w = [[0.0, 0.0, 0.0] for _ in range(33)]
    alto = 0.50

    def persona(x, y, z):
        # persona -> mundo MediaPipe: su derecha es -X, arriba es -Y, frente -Z
        return [-x, -(y + alto), -z]

    hi = [-ancho / 2, 0.0, 0.0]
    hd = [ancho / 2, 0.0, 0.0]
    w[ss.L_SHOULDER] = persona(*hi)
    w[ss.R_SHOULDER] = persona(*hd)
    w[ss.L_HIP] = persona(-ancho * 0.4, -alto, 0.0)
    w[ss.R_HIP] = persona(ancho * 0.4, -alto, 0.0)
    w[ss.NOSE] = persona(0.0, cuello, 0.08)
    w[ss.MOUTH_L] = persona(-0.025, cuello - 0.05, 0.07)
    w[ss.MOUTH_R] = persona(0.025, cuello - 0.05, 0.07)

    # brazo izquierdo colgando
    w[ss.L_ELBOW] = persona(-ancho / 2, -brazo, 0.0)
    w[ss.L_WRIST] = persona(-ancho / 2, -brazo - antebrazo, 0.0)
    w[ss.L_PINKY] = persona(-ancho / 2 - 0.02, -brazo - antebrazo - 0.07, 0.0)
    w[ss.L_INDEX] = persona(-ancho / 2 + 0.02, -brazo - antebrazo - 0.07, 0.0)

    # brazo derecho: IK analitica hacia la palma pedida
    palma_p = list(palma)
    muneca = [palma_p[0], palma_p[1] - 0.05, palma_p[2]]
    d = [muneca[i] - hd[i] for i in range(3)]
    dist = math.sqrt(sum(v * v for v in d))
    dist = min(dist, brazo + antebrazo - 1e-4)
    u = [v / max(1e-9, math.sqrt(sum(x * x for x in d))) for v in d]
    a = (brazo * brazo - antebrazo * antebrazo + dist * dist) / (2 * dist)
    h = math.sqrt(max(0.0, brazo * brazo - a * a))
    # codo hacia abajo y afuera
    perp = codo_r or [0.3, -0.95, 0.0]
    pd = sum(perp[i] * u[i] for i in range(3))
    perp = [perp[i] - pd * u[i] for i in range(3)]
    pl = math.sqrt(sum(v * v for v in perp)) or 1.0
    perp = [v / pl for v in perp]
    codo = [hd[i] + u[i] * a + perp[i] * h for i in range(3)]
    muneca = [hd[i] + u[i] * dist for i in range(3)]
    w[ss.R_ELBOW] = persona(*codo)
    w[ss.R_WRIST] = persona(*muneca)
    w[ss.R_PINKY] = persona(muneca[0] + 0.02, muneca[1] + 0.07, muneca[2])
    w[ss.R_INDEX] = persona(muneca[0] - 0.02, muneca[1] + 0.07, muneca[2])

    # giro alrededor de Y, escala y traslacion del mundo
    c, s = math.cos(giro), math.sin(giro)
    out = []
    for p in w:
        x, y, z = p
        x, z = c * x + s * z, -s * x + c * z
        out.append([x * escala + mover[0], y * escala + mover[1],
                    z * escala + mover[2]])

    pose = [[0.5, 0.5, 0.0, 0.95] for _ in range(33)]
    if not caderas:
        pose[ss.L_HIP][3] = 0.1
        pose[ss.R_HIP][3] = 0.1
    return pose, out
