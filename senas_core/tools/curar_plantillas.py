"""Curacion de plantillas.json v2 (post-proceso del paquete exportado).

Corre DESPUES de exportar_paquete.py / aprobar_dataset.py / moderar_senas.py --exportar
(esos scripts regeneran el JSON desde la base y borran cualquier arreglo hecho a mano):

    python tools/curar_plantillas.py assets/plantillas.json

Es idempotente: si el archivo ya trae "forma": "iso1" no vuelve a corregir la forma de la mano ni
a fabricar la J; solo repara, quita y reordena como siempre.

Que hace (y que NO hace):

  0. CORRIGE LA PROPORCION DE IMAGEN de la forma de la mano (lo nuevo, y lo que mas pesa).
     MediaPipe entrega los landmarks divididos por el ANCHO y el ALTO de la imagen por separado, asi
     que una mano filmada en 16:9 sale aplastada en x y z (0.56 de y) y la del bitmap de analisis del
     telefono (3:4) sale estirada (1.33). Dos tomas de la misma mano quedaban 2.4 veces distintas. Aqui
     se estima el aspecto de cada plantilla (consistencia de los largos de hueso contra las
     proporciones de una mano real, con preferencia por 16:9, que es lo que trae casi toda la base),
     se multiplican x y z por ese aspecto y se reescala la mano con la mediana de las distancias 3D
     muneca->nudillos (la escala 2D muneca->nudillo medio se dispara cuando la palma se inclina:
     M, N, ñ). Mismo calculo que sign_norm.isotropizar_forma, que es lo que hace el telefono con lo que
     ve la camara. Cada plantilla guarda su "aspecto". Medido con validacion cruzada por grabacion:
     acierto 28 % -> 34 % en general y 22 % -> 44 % en letras.
  1. Rellena huecos cortos de mano (<= 6 cuadros seguidos): la FORMA se copia del cuadro real mas
     cercano de la misma plantilla y, si en ese cuadro no habia mano, la POSICION se interpola
     entre dos cuadros reales. No inventa nada fuera de ese tramo.
  2. Detecta cuadros con geometria imposible de mano (nudillo a >1.6 veces su largo normal,
     dedos con proporciones absurdas) y, si caen en un hueco corto, rehace solo su forma
     (la posicion de la muneca de un cuadro con mano es real y no se toca).
  3. Quita del paquete las plantillas SIN MANO (cobertura < 5 %) cuando la misma sena tiene
     otra plantilla. Si es la unica, la deja y la lista en el reporte para volver a grabarla.
  4. Deja de PRIMERA (la que el Diccionario dibuja con el avatar) a la mejor plantilla de cada sena:
       * las 29 letras: la del video del alfabeto de la SEP (se reconoce por su huella; marca
         "fuente": "sep"). Revisadas letra por letra contra las fotos de la seña real.
       * la J: una plantilla FABRICADA ("sintetica": "J-hibrida") con el movimiento de la J mas
         amplia de la base (la de otra persona) y la mano de la J del alfabeto, de modo que el
         meñique queda levantado en TODOS los cuadros. La J del alfabeto SEP casi no se mueve y la
         amplia no mantiene el meñique firme. La original sigue en el paquete.
       * el resto: solo se mueve la primera si es mala (mano completa, sin cuadros corruptos, mano
         derecha como principal).

  4b. Y y Z: la camara estima mal el indice de esas letras (en la Y de la SEP el indice sale recto y
     queda "te quiero"; en la Z sale doblado porque apunta hacia la camara). Se FABRICA una plantilla
     nueva con la misma posicion y movimiento pero con ese dedo como debe ir ("sintetica":
     "Y-hibrida", "Z-recta"), y queda de primera. La original sigue en el paquete. Se omite con
     --sin-forma. (M y N~ NO se tocan: sus dedos van doblados desde el nudillo, y asi se ven bien.)

  5. Recorta las TRANSICIONES de las letras del alfabeto SEP: el video es continuo y los primeros / ultimos
     cuadros de cada letra todavia traen la mano de la letra de al lado (la M arrancaba con la mano de la L, la
     Z con la de la Y, la N con la de la M, la X y la Q cerraban abriendo la mano). Solo se reemplaza la FORMA de
     esos cuadros por la del primer / ultimo cuadro estable; el recorte no cambia el acierto medido y quita el
     "salto raro" al principio y al final de la animacion.

NO TOCA: el bloque de cuerpo (hombros, codos, munecas, caderas), la posicion de la mano
(loc) de ningun cuadro real, ni la altura a la que se hizo cada sena. Una mano que se
grabo entre la cabeza y el pecho, o mas arriba, se queda exactamente ahi (el script lo verifica
con aserciones; en la J fabricada la posicion y el cuerpo son los de la plantilla de la que sale).

El respaldo del original se guarda en tools/_respaldo_antes_de_curar/ (fuera de assets/); solo se
conservan los 3 mas recientes.

Solo usa la biblioteca estandar de Python.
"""
import argparse
import csv
import glob
import json
import math
import os
import shutil
import sys
import time

T, D = 32, 152
OFF_LOC = (24, 27)
OFF_PRES = (30, 31)
OFF_SHAPE = (32, 92)   # izq, der

FORMA_ISO = "iso1"
ASPECTOS = (16.0 / 9.0, 4.0 / 3.0, 1.0, 3.0 / 4.0, 9.0 / 16.0)   # ancho / alto
ASPECTO_DEFECTO = 16.0 / 9.0
SESGO_16_9 = 0.15     # otro aspecto solo gana si su dispersion es 15 % menor que la de 16:9
MIN_CUADROS_ASPECTO = 8

# --- debe coincidir con sign_norm.REF_PALMA / IDX_PALMA / isotropizar_forma (se verifica abajo) ---
REF_PALMA = (1.07, 1.01, 0.92, 0.84)
IDX_PALMA = (4, 8, 12, 16)
N_PTS = 20

BONES = [(1, 2), (2, 3), (3, 4), (5, 6), (6, 7), (7, 8), (9, 10), (10, 11), (11, 12), (13, 14), (14, 15), (15, 16),
         (17, 18), (18, 19), (19, 20)]
REF = [0.41, 0.31, 0.24, 0.43, 0.25, 0.20, 0.45, 0.26, 0.20, 0.42, 0.24, 0.18, 0.33, 0.19, 0.15]
# huesos + palma (para estimar el aspecto)
BONES_ASP = BONES + [(0, 5), (0, 9), (0, 13), (0, 17), (5, 9), (9, 13), (13, 17)]
LOGREF_ASP = [math.log(r) for r in REF + [1.07, 1.01, 0.92, 0.84, 0.20, 0.23, 0.24]]

MAXGAP = 6
# recorte de transiciones del alfabeto: un cuadro es "de transicion" si su forma se aleja de la forma estable
# (mediana de los cuadros 12-20) mas de REC_TH, o mas de REC_FUERTE el solo
REC_TH, REC_FUERTE = 0.20, 0.40
REC_NUCLEO = (12, 20)
DECIMALES = 5       # la forma corregida trae muchos decimales de mas; 5 bastan (el original trae float16)
LIM_PALMA, LIM_RANGO, LIM_ESC = 1.6, 8.0, 4.5
UMBRAL_SIN_MANO = 0.05
COB_MIN_PRIMERA = 0.90      # para ser la primera plantilla: mano valida en >=90 % de los cuadros
MALOS_MAX_PRIMERA = 0.10    # y como mucho 10 % de cuadros con geometria dudosa
# gloss -> criterio para elegir la primera cuando no hay plantilla de referencia fija.
# horizontal = mano acostada; amplio = el movimiento mas grande; limpia = la de mejor calidad.
PREFERENCIAS = {}

# Huella de las 29 plantillas del video del alfabeto de la SEP (forma de la mano en 3 cuadros, norm
# 2.0.0 sin corregir). Con ellas se reconocen las plantillas aunque el orden del archivo cambie.
SEP_HUELLAS = {
    'A': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.2544, 0.186, -0.0877, -0.4602, 0.5444, -0.1324, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.2408, 0.2203, -0.0883, -0.4019, 0.6206, -0.1268, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.2356, 0.1904, -0.0876, -0.3943, 0.6289, -0.119],
    'B': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1626, 0.2085, -0.0906, -0.2294, 0.5229, -0.1164, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1542, 0.2125, -0.0897, -0.2167, 0.5376, -0.1158, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1497, 0.225, -0.0889, -0.2139, 0.5464, -0.1167],
    'C': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.2028, 0.1801, -0.0193, -0.3816, 0.4106, -0.0791, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1805, 0.1641, -0.0222, -0.3472, 0.4082, -0.0707, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1726, 0.1632, -0.0311, -0.3367, 0.4065, -0.081],
    'D': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1409, 0.187, -0.1028, -0.2235, 0.4106, -0.1824, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1433, 0.1855, -0.1022, -0.2296, 0.3936, -0.1842, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1448, 0.1816, -0.1058, -0.2284, 0.386, -0.1895],
    'E': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.2164, 0.0693, -0.0634, -0.3691, 0.3599, -0.0965, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.215, 0.0696, -0.0763, -0.3657, 0.3647, -0.1138, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.2196, 0.0699, -0.074, -0.3757, 0.3682, -0.1137],
    'F': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1754, 0.2023, -0.0543, -0.2681, 0.5059, -0.077, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1759, 0.196, -0.061, -0.27, 0.5015, -0.0867, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1769, 0.1964, -0.0578, -0.27, 0.501, -0.082],
    'G': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.046, 0.5615, 0.0224, -0.0462, 1.124, 0.0023, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.035, 0.5562, 0.022, -0.0707, 1.125, 0.0032, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0434, 0.5557, 0.0258, -0.057, 1.1074, 0.0054],
    'H': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0009, 0.5688, 0.0081, -0.1198, 1.1494, -0.0192, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.0051, 0.5635, 0.0148, -0.1211, 1.1436, -0.0084, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.0017, 0.5444, 0.0039, -0.1175, 1.1104, -0.0267],
    'I': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.2101, 0.1409, -0.0665, -0.373, 0.4631, -0.0812, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.2064, 0.1564, -0.0655, -0.3625, 0.4941, -0.0793, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.2078, 0.172, -0.0636, -0.3506, 0.5225, -0.0766],
    'J': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.1942, 0.4639, 0.0104, 0.2426, 1.0156, -0.0255, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.2155, 0.4546, 0.014, 0.2922, 0.9761, -0.0223, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.2156, 0.4521, 0.0055, 0.2937, 0.9653, -0.032],
    'K': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1621, 0.2159, -0.0872, -0.1903, 0.6396, -0.1143, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1439, 0.2656, -0.0809, -0.1567, 0.6694, -0.1114, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1427, 0.2676, -0.0773, -0.1599, 0.6479, -0.1113],
    'L': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.196, 0.1176, -0.0875, -0.3743, 0.3555, -0.1643, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1927, 0.1177, -0.0836, -0.3711, 0.365, -0.1541, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1897, 0.117, -0.0842, -0.3618, 0.3679, -0.1527],
    'LL': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.2039, 0.1215, -0.0912, -0.397, 0.3828, -0.1486, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1987, 0.1117, -0.0923, -0.3918, 0.3682, -0.1541, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1923, 0.1237, -0.09, -0.376, 0.4014, -0.1489],
    'M': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.6938, -0.0995, -0.3223, -1.1787, -0.5913, -0.7036, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.7173, -0.0817, -0.3618, -1.2373, -0.5332, -0.751, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.4902, -0.0016, -0.2598, -0.9009, -0.2389, -0.5239],
    'N': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.939, -0.4443, -0.4231, -1.5088, -1.7617, -0.8403, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.6924, -0.1885, -0.3318, -1.1152, -1.2178, -0.6147, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.8198, -0.1729, -0.3879, -1.334, -1.3594, -0.7695],
    'NN': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -9.5625, -3.7109, -4.0586, -17.3281, -12.2266, -7.4102, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -1.1055, -0.0948, -0.5894, -1.9492, -0.4297, -1.1318, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.5903, 0.1118, -0.2969, -1.0225, 0.1222, -0.5747],
    'O': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1692, 0.2186, 0.0204, -0.2886, 0.4802, -0.0044, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1669, 0.2227, 0.021, -0.2859, 0.4746, -0.0035, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1663, 0.2253, 0.0219, -0.2837, 0.4814, -0.0012],
    'P': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1541, 0.244, -0.0907, -0.1893, 0.6328, -0.124, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1519, 0.2444, -0.086, -0.1864, 0.626, -0.116, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1527, 0.2551, -0.0833, -0.1807, 0.6401, -0.1141],
    'Q': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1946, 0.0052, -0.1365, -0.3867, 0.0723, -0.2849, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.2007, 0.0235, -0.1262, -0.3945, 0.1123, -0.2644, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1942, 0.0056, -0.1445, -0.3801, 0.0679, -0.2996],
    'R': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1798, 0.1611, -0.0928, -0.28, 0.4219, -0.1366, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1803, 0.1672, -0.0895, -0.2805, 0.4314, -0.1311, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1782, 0.1635, -0.0945, -0.28, 0.4236, -0.14],
    'RR': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1506, 0.1792, -0.097, -0.2252, 0.4595, -0.1396, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.153, 0.1901, -0.0939, -0.2338, 0.4712, -0.1357, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1493, 0.197, -0.0912, -0.2234, 0.4844, -0.1315],
    'S': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1899, 0.2161, -0.0718, -0.3198, 0.6543, -0.0931, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1931, 0.2422, -0.0645, -0.312, 0.6792, -0.0856, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1929, 0.2411, -0.0619, -0.3057, 0.6851, -0.0816],
    'T': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.2054, 0.1853, -0.0959, -0.2908, 0.6816, -0.1157, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1953, 0.1852, -0.0944, -0.2693, 0.6753, -0.1149, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.2006, 0.1987, -0.0901, -0.2622, 0.6943, -0.1067],
    'U': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1422, 0.1997, -0.0974, -0.1871, 0.5005, -0.1372, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1379, 0.2157, -0.0906, -0.1748, 0.5166, -0.1277, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1311, 0.213, -0.09, -0.1554, 0.5195, -0.1256],
    'V': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1288, 0.2128, -0.0848, -0.1555, 0.5142, -0.1251, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1288, 0.2169, -0.0865, -0.1555, 0.5186, -0.1255, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1299, 0.2148, -0.0886, -0.1608, 0.5176, -0.1304],
    'W': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1096, 0.1768, -0.0867, -0.1263, 0.4734, -0.1185, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1087, 0.1848, -0.0856, -0.1214, 0.4863, -0.1163, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1086, 0.189, -0.084, -0.1213, 0.4902, -0.1132],
    'X': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.157, 0.6348, -0.0285, -0.3713, 1.2354, -0.1212, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.125, 0.624, -0.0107, -0.3247, 1.2148, -0.0899, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1248, 0.6011, -0.014, -0.3135, 1.1836, -0.0961],
    'Y': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0825, 0.6064, -0.0268, 0.0296, 1.1875, -0.0701, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0846, 0.6089, -0.0263, 0.0261, 1.1904, -0.0658, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0839, 0.5947, -0.0294, 0.0138, 1.1699, -0.0683],
    'Z': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1343, 0.1725, -0.1434, -0.165, 0.4055, -0.2191, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1302, 0.1567, -0.1154, -0.1871, 0.4006, -0.1853, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1298, 0.1648, -0.1149, -0.1776, 0.416, -0.1841],
}
SEP_TOL = 2e-3

# ---------------------------------------------------------------------------------------------
# Forma isotropica (misma cuenta que sign_norm.isotropizar_forma)
# ---------------------------------------------------------------------------------------------


def iso_forma(forma, aspecto):
    p = [[forma[i * 3] * aspecto, forma[i * 3 + 1], forma[i * 3 + 2] * aspecto] for i in range(N_PTS)]
    r = sorted(math.sqrt(p[j][0] ** 2 + p[j][1] ** 2 + p[j][2] ** 2) / ref for j, ref in zip(IDX_PALMA, REF_PALMA))
    hs = (r[1] + r[2]) / 2.0
    if hs < 1e-6:
        hs = 1.0
    out = []
    for q in p:
        out.extend((q[0] / hs, q[1] / hs, q[2] / hs))
    return out


def iso_secuencia(seq, aspecto):
    out = []
    for f in seq:
        g = list(f)
        for h in (0, 1):
            if f[OFF_PRES[h]] >= 0.5:
                g[OFF_SHAPE[h]:OFF_SHAPE[h] + 60] = iso_forma(f[OFF_SHAPE[h]:OFF_SHAPE[h] + 60], aspecto)
        out.append(g)
    return out


def verificar_contra_sign_norm():
    """Si sign_norm.py (el de la app) esta a mano, comprueba que hace exactamente la misma cuenta."""
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import sign_norm as sn
        if not hasattr(sn, "isotropizar_forma"):
            return "sign_norm.py de esta carpeta es anterior a la forma isotropica (no se compara)"
    except Exception:
        return "sign_norm.py no disponible (no se compara)"
    prueba = [0.3 * math.sin(i * 1.7) + 0.05 * (i % 5) for i in range(60)]
    for a in (16.0 / 9.0, 0.75):
        d = max(abs(x - y) for x, y in zip(sn.isotropizar_forma(prueba, a), iso_forma(prueba, a)))
        if d > 1e-12 or tuple(sn.REF_PALMA) != REF_PALMA or tuple(sn.IDX_PALMA) != IDX_PALMA:
            sys.exit("curar_plantillas.py y sign_norm.py calculan distinto la forma isotropica; arreglalo antes de seguir")
    return "coincide con sign_norm.isotropizar_forma"


# ---------------------------------------------------------------------------------------------
# Estimacion del aspecto de cada plantilla
# ---------------------------------------------------------------------------------------------


def manos_nube(seq):
    """Lista de manos (21 puntos con la muneca en el origen) de todos los cuadros con mano valida."""
    out = []
    for fr in seq:
        for h in (0, 1):
            if fr[OFF_PRES[h]] < 0.5:
                continue
            off = OFF_SHAPE[h]
            blk = fr[off:off + 60]
            if sum(abs(v) for v in blk) < 1e-9:
                continue
            out.append([(0.0, 0.0, 0.0)] + [(blk[i * 3], blk[i * 3 + 1], blk[i * 3 + 2]) for i in range(N_PTS)])
    return out


def dispersion(manos, a):
    acc = 0.0
    n = 0
    for P in manos:
        Q = [(p[0] * a, p[1], p[2] * a) for p in P]
        lr = []
        for (i, j), lg in zip(BONES_ASP, LOGREF_ASP):
            lr.append(math.log(max(math.dist(Q[i], Q[j]), 1e-6)) - lg)
        s = sorted(lr)
        med = (s[10] + s[11]) / 2.0
        for v in lr:
            acc += (v - med) ** 2
        n += len(lr)
    return math.sqrt(acc / n)


def estimar_aspecto(seq):
    """(aspecto, dispersion_16_9, dispersion_elegida) para una plantilla en formato 2.0.0 crudo."""
    manos = manos_nube(seq)
    if len(manos) < MIN_CUADROS_ASPECTO:
        return ASPECTO_DEFECTO, None, None
    d = [dispersion(manos, a) for a in ASPECTOS]
    j = min(range(len(ASPECTOS)), key=lambda k: d[k])
    if j != 0 and d[j] < d[0] * (1.0 - SESGO_16_9):
        return ASPECTOS[j], d[0], d[j]
    return ASPECTO_DEFECTO, d[0], d[0]


# ---------------------------------------------------------------------------------------------
# Geometria de la mano por cuadro (reparacion y calidad)
# ---------------------------------------------------------------------------------------------


def puntos(frame, h):
    off = OFF_SHAPE[h]
    p = [(0.0, 0.0, 0.0)]
    for i in range(20):
        p.append((frame[off + 3 * i], frame[off + 3 * i + 1], frame[off + 3 * i + 2]))
    return p


def metricas_cuadro(frame, h):
    """(presente, mala_geometria, eje_unit) de una mano en un cuadro."""
    pres = frame[OFF_PRES[h]] >= 0.5
    p = puntos(frame, h)
    if not pres or all(abs(c) < 1e-9 for q in p[1:] for c in q):
        return False, False, None
    L = []
    for (a, b), r in zip(BONES, REF):
        L.append(math.dist(p[a], p[b]) / r)
    s = sorted(L)
    esc = (s[7])                       # mediana de 15
    dedos = L[3:]
    rango = max(dedos) / max(min(dedos), 1e-6)
    palma = math.sqrt(sum(c * c for c in p[9]))
    mala = palma > LIM_PALMA or rango > LIM_RANGO or esc > LIM_ESC
    n = palma if palma > 1e-9 else 1.0
    eje = (p[9][0] / n, p[9][1] / n, -p[9][2] / n)     # z de la mano -> z hacia el frente
    return True, mala, eje


def analizar(seq):
    """por mano: listas pres[T], mala[T], eje[T]"""
    out = []
    for h in (0, 1):
        pres, mala, eje = [], [], []
        for fr in seq:
            a, b, e = metricas_cuadro(fr, h)
            pres.append(a)
            mala.append(b)
            eje.append(e)
        out.append((pres, mala, eje))
    return out


def reparar(seq):
    """Devuelve (seq_nueva, rellenados[2], malos_antes[2]) sin modificar la original."""
    seq = [list(f) for f in seq]
    an = analizar(seq)
    rell = [0, 0]
    malos = [0, 0]
    for h in (0, 1):
        pres, mala, _ = an[h]
        malos[h] = sum(1 for a, b in zip(pres, mala) if a and b)
        valido = [a and not b for a, b in zip(pres, mala)]
        if sum(valido) < 2:
            continue
        c_forma = list(range(OFF_SHAPE[h], OFF_SHAPE[h] + 60))
        c_loc = list(range(OFF_LOC[h], OFF_LOC[h] + 3))
        j = 0
        while j < T:
            if valido[j]:
                j += 1
                continue
            k = j
            while k < T and not valido[k]:
                k += 1
            if j > 0 and k < T and (k - j) <= MAXGAP:
                a, b = j - 1, k          # extremos reales
                for t in range(j, k):
                    w = (t - a) / (b - a)
                    # cuadro con mano pero forma dudosa: la POSICION (loc) es real y se conserva;
                    # solo se interpola la forma. Cuadro sin mano: no hay nada real, se interpola todo.
                    # Forma: se COPIA la del cuadro real mas cercano (mezclar dos formas encoge los dedos
                    # y produce una mano que no existe). Posicion de cuadros sin mano: interpolada.
                    src = a if (t - a) <= (b - t) else b
                    for c in c_forma:
                        seq[t][c] = seq[src][c]
                    if not pres[t]:
                        for c in c_loc:
                            seq[t][c] = round(seq[a][c] * (1 - w) + seq[b][c] * w, 6)
                    seq[t][OFF_PRES[h]] = 1.0
                    rell[h] += 1
            j = k
    return seq, rell, malos


def recortar_transiciones(seq):
    """Las 29 plantillas del alfabeto SEP salen de UN video continuo: los primeros y ultimos cuadros de cada
    segmento todavia llevan la mano de la letra de al lado (la M arrancaba con la mano de la L, la Z con la de la
    Y, la N con la de la M...). Aqui la FORMA de esos cuadros se reemplaza por la del primer / ultimo cuadro
    estable de esa misma plantilla. La posicion (loc), el cuerpo y la presencia NO se tocan.
    Devuelve (secuencia nueva, cuadros cambiados)."""
    seq = [list(f) for f in seq]
    cambiados = set()
    c0, c1 = REC_NUCLEO
    centro = (c0 + c1) // 2
    for h in (0, 1):
        pres = [f[OFF_PRES[h]] >= 0.5 for f in seq]
        if sum(pres) < 8:
            continue
        o = OFF_SHAPE[h]
        sh = [f[o:o + 60] for f in seq]
        idx = [t for t in range(c0, c1 + 1) if pres[t]]
        if len(idx) < 3:
            continue
        core = []
        for c in range(60):
            v = sorted(sh[t][c] for t in idx)
            m = len(v) // 2
            core.append(v[m] if len(v) % 2 else (v[m - 1] + v[m]) / 2.0)
        d = [math.sqrt(sum((x - y) ** 2 for x, y in zip(sh[t], core)) / 60.0) if pres[t] else 0.0 for t in range(T)]
        malo = [False] * T
        for t in range(T):
            if not pres[t] or c0 <= t <= c1:
                continue
            if d[t] > REC_FUERTE:
                malo[t] = True
            elif d[t] > REC_TH:
                izq = t > 0 and pres[t - 1] and d[t - 1] > REC_TH
                der = t < T - 1 and pres[t + 1] and d[t + 1] > REC_TH
                malo[t] = izq or der
        ant = [t for t in range(0, c0) if malo[t]]
        pos = [t for t in range(c1 + 1, T) if malo[t]]
        ta = (max(ant) + 1) if ant else 0
        tb = (min(pos) - 1) if pos else T - 1
        ta = next((t for t in range(ta, centro + 1) if pres[t] and d[t] <= REC_TH), None)
        tb = next((t for t in range(tb, centro - 1, -1) if pres[t] and d[t] <= REC_TH), None)
        if ta is None or tb is None:
            continue
        for t in range(0, ta):
            if pres[t] and sh[t] != sh[ta]:
                seq[t][o:o + 60] = sh[ta]
                cambiados.add(t)
        for t in range(tb + 1, T):
            if pres[t] and sh[t] != sh[tb]:
                seq[t][o:o + 60] = sh[tb]
                cambiados.add(t)
    return seq, len(cambiados)


def calidad(seq):
    """dict con cobertura de cada mano, mano dominante, malos tras reparar, amplitud, horizontalidad."""
    an = analizar(seq)
    cov = []
    mal = []
    for h in (0, 1):
        pres, mala, _ = an[h]
        cov.append(sum(1 for a, b in zip(pres, mala) if a and not b) / T)
        mal.append(sum(1 for a, b in zip(pres, mala) if a and b) / T)
    dom = 1 if cov[1] >= cov[0] else 0
    pres, mala, eje = an[dom]
    ev = [e for a, b, e in zip(pres, mala, eje) if a and not b]
    amp = 0.0
    for i in range(len(ev)):
        for j in range(i + 1, len(ev)):
            c = max(-1.0, min(1.0, sum(x * y for x, y in zip(ev[i], ev[j]))))
            amp = max(amp, math.degrees(math.acos(c)))
    if ev:
        ys = sorted(abs(e[1]) for e in ev)
        hor = ys[len(ys) // 2]
    else:
        hor = 1.0
    dos_manos = min(cov) >= 0.5
    return dict(cov=cov, mal=mal, dom=dom, amp=amp, hor=hor, dos_manos=dos_manos)


def es_buena(q):
    c = q["cov"][q["dom"]]
    m = q["mal"][q["dom"]]
    mano_ok = (q["dom"] == 1) or q["dos_manos"]
    return c >= COB_MIN_PRIMERA and m <= MALOS_MAX_PRIMERA and mano_ok


def elegir(indices, Q, criterio):
    """indices candidatos (de una sena); devuelve el indice elegido o None."""
    buenos = [i for i in indices if es_buena(Q[i])]
    if not buenos:
        return None
    if criterio == "horizontal":
        return min(buenos, key=lambda i: (Q[i]["hor"], indices.index(i)))
    if criterio == "amplio":
        return max(buenos, key=lambda i: (Q[i]["amp"], -indices.index(i)))
    # limpia: mano valida en todos los cuadros, sin cuadros dudosos y SIN interpolar (datos reales primero)
    return max(buenos, key=lambda i: (Q[i]["cov"][Q[i]["dom"]] - Q[i]["mal"][Q[i]["dom"]] - 0.5 * Q[i]["rell"],
                                      -indices.index(i)))


# ---------------------------------------------------------------------------------------------
# La J con el menique siempre arriba
# ---------------------------------------------------------------------------------------------
CADENAS = [(1, (2, 3, 4)), (5, (6, 7, 8)), (9, (10, 11, 12)), (13, (14, 15, 16)), (17, (18, 19, 20))]
VENTANA_ROT = (1, 2, 3, 2, 1)


def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _unit(a):
    n = math.sqrt(_dot(a, a))
    return None if n < 1e-9 else (a[0] / n, a[1] / n, a[2] / n)


def puntos20(frame, h):
    off = OFF_SHAPE[h]
    return [(frame[off + 3 * i], frame[off + 3 * i + 1], frame[off + 3 * i + 2]) for i in range(N_PTS)]


def base_palma(P):
    """Base ortonormal (3 vectores) de la palma, desde muneca->MCP9 y MCP5->MCP17. None si degenerada."""
    e1 = _unit(P[8])
    if e1 is None:
        return None
    d = _sub(P[16], P[4])
    k = _dot(d, e1)
    e2 = _unit((d[0] - k * e1[0], d[1] - k * e1[1], d[2] - k * e1[2]))
    if e2 is None:
        return None
    return (e1, e2, _cross(e1, e2))


def rotacion(Bt, Bref):
    """R = Bt * Bref^T: lleva la palma de referencia a la orientacion del cuadro t. 3x3 por filas."""
    return [[sum(Bt[k][i] * Bref[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def ortonormalizar(R):
    c0 = _unit((R[0][0], R[1][0], R[2][0]))
    c1 = (R[0][1], R[1][1], R[2][1])
    if c0 is None:
        return None
    k = _dot(c1, c0)
    c1 = _unit((c1[0] - k * c0[0], c1[1] - k * c0[1], c1[2] - k * c0[2]))
    if c1 is None:
        return None
    c2 = _cross(c0, c1)
    return [[c0[i], c1[i], c2[i]] for i in range(3)]


def aplicar(R, v):
    return (R[0][0] * v[0] + R[0][1] * v[1] + R[0][2] * v[2],
            R[1][0] * v[0] + R[1][1] * v[1] + R[1][2] * v[2],
            R[2][0] * v[0] + R[2][1] * v[1] + R[2][2] * v[2])


def rectitud(P, cadena):
    """cuerda / largo de la cadena de 4 puntos (1 = dedo recto, ~0.3 = doblado)."""
    pts = [P[c - 1] for c in cadena]
    largo = sum(math.dist(pts[i], pts[i + 1]) for i in range(3))
    return math.dist(pts[0], pts[3]) / largo if largo > 1e-9 else 0.0


def elegir_referencia_i(seq_sep, h):
    """Forma de mano 'I' (menique recto, los demas cerrados) mas tipica de la J del alfabeto."""
    cand = []
    for fr in seq_sep:
        if fr[OFF_PRES[h]] < 0.5:
            continue
        P = puntos20(fr, h)
        if (rectitud(P, (17, 18, 19, 20)) >= 0.95 and rectitud(P, (5, 6, 7, 8)) <= 0.55
                and rectitud(P, (9, 10, 11, 12)) <= 0.55 and rectitud(P, (13, 14, 15, 16)) <= 0.6):
            cand.append(P)
    if not cand:
        return None
    med = [tuple(sorted(P[i][c] for P in cand)[len(cand) // 2] for c in range(3)) for i in range(N_PTS)]
    return min(cand, key=lambda P: sum(math.dist(P[i], med[i]) ** 2 for i in range(N_PTS)))


def construir_j_hibrida(tray, ref):
    """tray: secuencia (T x 152, ya corregida) con el movimiento deseado; ref: 20 puntos de la mano 'I'.

    Conserva de `tray` el cuerpo, la posicion y la orientacion de la palma (muneca y nudillos) en cada
    cuadro, y cambia los dedos por los de `ref`: cada cadena (pulgar, indice, ...) se ancla en el
    nudillo de `tray` y se orienta con la rotacion que lleva la palma de `ref` a la palma de `tray`
    (suavizada en el tiempo). Los largos de hueso son los de `ref`."""
    q = calidad(tray)
    h = q["dom"]
    Bref = base_palma(ref)
    if Bref is None:
        return None, "referencia degenerada"
    Rs = []
    for t in range(T):
        if tray[t][OFF_PRES[h]] < 0.5:
            Rs.append(None)
            continue
        Bt = base_palma(puntos20(tray[t], h))
        Rs.append(None if Bt is None else rotacion(Bt, Bref))
    if all(r is None for r in Rs):
        return None, "ningun cuadro con palma valida"
    # rellena palmas degeneradas con la mas cercana en el tiempo
    for t in range(T):
        if Rs[t] is None and tray[t][OFF_PRES[h]] >= 0.5:
            mejor = min((abs(u - t), u) for u in range(T) if Rs[u] is not None)[1]
            Rs[t] = Rs[mejor]
    suaves = []
    for t in range(T):
        if Rs[t] is None:
            suaves.append(None)
            continue
        acc = [[0.0] * 3 for _ in range(3)]
        w = 0
        for dt, wt in zip(range(-2, 3), VENTANA_ROT):
            u = t + dt
            if 0 <= u < T and Rs[u] is not None:
                for i in range(3):
                    for j in range(3):
                        acc[i][j] += wt * Rs[u][i][j]
                w += wt
        acc = [[v / w for v in fila] for fila in acc]
        suaves.append(ortonormalizar(acc) or Rs[t])
    out = [list(f) for f in tray]
    for t in range(T):
        if suaves[t] is None:
            continue
        P = puntos20(tray[t], h)
        for ancla, resto in CADENAS:
            for j in resto:
                v = aplicar(suaves[t], _sub(ref[j - 1], ref[ancla - 1]))
                P[j - 1] = (P[ancla - 1][0] + v[0], P[ancla - 1][1] + v[1], P[ancla - 1][2] + v[2])
        off = OFF_SHAPE[h]
        for i, p in enumerate(P):
            out[t][off + 3 * i] = round(p[0], 6)
            out[t][off + 3 * i + 1] = round(p[1], 6)
            out[t][off + 3 * i + 2] = round(p[2], 6)
    return out, h


# ---------------------------------------------------------------------------------------------
# Letras cuya mano en el video no coincide con la seña (revisadas contra el abecedario de la SEP)
# ---------------------------------------------------------------------------------------------
# La camara estima mal algunos dedos de la letra: en la Y de la SEP el indice sale recto (queda "te
# quiero") y en la Z el indice sale doblado porque apunta hacia la camara. (La M y la Ñ se probaron y
# NO se corrigen: al estirar sus dedos en el eje de la palma quedaban apuntando hacia arriba en vez de
# colgar sobre el antebrazo; los originales ya se ven como el dibujo.) Para Y y Z se FABRICA una
# plantilla nueva (misma posicion,
# mismo cuerpo y mismo movimiento; solo cambia la FORMA de esos dedos) que se pone de primera; la
# original sigue en el paquete. Cada correccion es (tipo, dedo[, dedo_modelo]) con dedo 0 = indice ...
# 3 = menique.
FORMA_CORREGIDA = {
    "Y": ("Y-hibrida", [("curvar", 0, 1)],
          "indice doblado como el medio: la Y lleva afuera solo el pulgar y el menique"),
    "Z": ("Z-recta", [("enderezar", 0)],
          "indice recto: la camara lo ve de frente y lo estima doblado"),
}


def _norma(a):
    return math.sqrt(_dot(a, a))


def _mas(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def _por(a, s):
    return (a[0] * s, a[1] * s, a[2] * s)


def enderezar_dedo(P, dedo):
    """Estira el dedo COMPLETO (0 = indice ... 3 = menique): las tres falanges quedan en linea, siguiendo la
    direccion muneca -> nudillo del propio dedo mezclada con el eje de la palma (muneca -> nudillo medio), asi
    la flexion del nudillo tambien vale ~0 (antes solo se estiraban las dos falanges de la punta y la primera
    seguia doblada). Conserva el largo de cada hueso y el nudillo en su lugar."""
    b = 4 + 4 * dedo
    d1 = _unit(P[b])      # la forma va relativa a la muneca: P[b] es el vector muneca -> nudillo
    d2 = _unit(P[8])      # eje de la palma (nudillo del medio)
    if d1 is None or d2 is None:
        return False
    d = _unit(_mas(d1, d2))
    if d is None:
        return False
    l0 = _norma(_sub(P[b + 1], P[b]))
    l1 = _norma(_sub(P[b + 2], P[b + 1]))
    l2 = _norma(_sub(P[b + 3], P[b + 2]))
    P[b + 1] = _mas(P[b], _por(d, l0))
    P[b + 2] = _mas(P[b + 1], _por(d, l1))
    P[b + 3] = _mas(P[b + 2], _por(d, l2))
    return True


def curvar_como(P, dedo, modelo):
    """Da al dedo la curva del dedo `modelo` (mismos giros de cada hueso, escalados al largo de su primer hueso)."""
    b, o = 4 + 4 * dedo, 4 + 4 * modelo
    lb = _norma(_sub(P[b + 1], P[b]))
    lo = _norma(_sub(P[o + 1], P[o]))
    if lo < 1e-9:
        return False
    esc = lb / lo
    for k in (1, 2, 3):
        P[b + k] = _mas(P[b], _por(_sub(P[o + k], P[o]), esc))
    return True


def construir_forma_corregida(seq, correcciones):
    """Copia de `seq` con la forma de los dedos corregida en cada cuadro con mano. Devuelve (nueva, h_dom)."""
    nueva = [list(fr) for fr in seq]
    for fr in nueva:
        for h in (0, 1):
            if fr[OFF_PRES[h]] < 0.5:
                continue
            P = [list(p) for p in puntos20(fr, h)]
            if all(abs(c) < 1e-9 for p in P for c in p):
                continue
            for c in correcciones:
                if c[0] == "enderezar":
                    enderezar_dedo(P, c[1])
                else:
                    curvar_como(P, c[1], c[2])
            off = OFF_SHAPE[h]
            for i, p in enumerate(P):
                fr[off + 3 * i], fr[off + 3 * i + 1], fr[off + 3 * i + 2] = p
    return nueva


# ---------------------------------------------------------------------------------------------
# Principal
# ---------------------------------------------------------------------------------------------


def es_sep(p):
    g = p["gloss"].upper()
    h = SEP_HUELLAS.get(g)
    if h is None:
        return False
    seq = p["seq"]
    v = []
    for t in (8, 16, 24):
        v += [round(x, 4) for x in seq[t][32:38]]
        v += [round(x, 4) for x in seq[t][92:98]]
    return max(abs(a - b) for a, b in zip(v, h)) < SEP_TOL


def prioridad(p):
    if p.get("sintetica"):
        return 2
    if p.get("fuente") == "sep":
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("entrada")
    ap.add_argument("--salida", help="por defecto sobrescribe la entrada (con respaldo)")
    ap.add_argument("--reporte", help="CSV con lo que se hizo (default: datasets_lsm/curacion_plantillas_<fecha>.csv)")
    ap.add_argument("--sin-reordenar", action="store_true")
    ap.add_argument("--sin-quitar", action="store_true", help="no quitar plantillas sin mano")
    ap.add_argument("--sin-iso", action="store_true",
                    help="NO corregir la proporcion de imagen (deja el paquete como antes; la app lo corrige con 16:9)")
    ap.add_argument("--sin-j", action="store_true", help="no fabricar la J con menique arriba")
    ap.add_argument("--sin-forma", action="store_true",
                    help="no fabricar las plantillas corregidas de Y y Z (ver FORMA_CORREGIDA)")
    ap.add_argument("--sin-recorte", action="store_true",
                    help="no recortar las transiciones de los extremos de las letras del alfabeto SEP")
    ap.add_argument("--prefer", action="append", default=[], metavar="GLOSA=criterio",
                    help="criterio: horizontal | amplio | limpia (se suma a PREFERENCIAS)")
    ap.add_argument("--solo-reporte", action="store_true")
    ap.add_argument("--sin-respaldo", action="store_true", help="no guardar .bak junto al archivo (lo usa moderar_senas, que ya respalda)")
    a = ap.parse_args()

    pref = dict(PREFERENCIAS)
    for x in a.prefer:
        g, c = x.split("=", 1)
        pref[g.upper()] = c

    print("forma isotropica:", verificar_contra_sign_norm())
    with open(a.entrada, encoding="utf-8") as f:
        pkg = json.load(f)
    if pkg.get("norm_version") != "2.0.0" or pkg.get("t_frames") != T or pkg.get("frame_dim") != D:
        sys.exit("El paquete no es norm 2.0.0 / 32x152; este script no lo entiende.")
    ya_iso = pkg.get("forma") == FORMA_ISO
    pl = pkg["plantillas"]
    n0 = len(pl)
    print(f"paquete: {n0} plantillas, forma={'ya corregida (iso1)' if ya_iso else 'cruda 2.0.0'}")

    # --- 0: reconocer el alfabeto SEP (sobre datos crudos) y corregir la proporcion de imagen
    t0 = time.time()
    for p in pl:
        p["_seq_orig"] = p["seq"]
        if not ya_iso:
            if es_sep(p):
                p["fuente"] = "sep"
            if a.sin_iso:
                p["aspecto"] = round(float(p.get("aspecto", ASPECTO_DEFECTO)), 4)
            else:
                asp = p.get("aspecto")
                if asp is None:
                    asp = estimar_aspecto(p["seq"])[0]
                p["aspecto"] = round(float(asp), 4)
                p["seq"] = iso_secuencia(p["seq"], p["aspecto"])
    if not ya_iso:
        cuenta = {}
        for p in pl:
            cuenta[round(p["aspecto"], 3)] = cuenta.get(round(p["aspecto"], 3), 0) + 1
        print("aspecto estimado por plantilla:",
              ", ".join(f"{k:.3f}: {v}" for k, v in sorted(cuenta.items(), reverse=True)),
              f"({time.time() - t0:.0f} s)")
        n_sep = sum(1 for p in pl if p.get("fuente") == "sep")
        print(f"plantillas del alfabeto SEP reconocidas: {n_sep} de {len(SEP_HUELLAS)}")
        if n_sep < len(SEP_HUELLAS):
            falt = sorted(set(SEP_HUELLAS) - {p["gloss"].upper() for p in pl if p.get("fuente") == "sep"})
            print("  sin plantilla del alfabeto (usan el criterio de calidad):", ", ".join(falt))

    # --- 1-2: reparar
    rep = []
    recort = []
    Q0 = []
    for p in pl:
        q0 = calidad(p["seq"])
        nueva, rell, malos = reparar(p["seq"])
        nrec = 0
        if p.get("fuente") == "sep" and not a.sin_recorte:
            nueva, nrec = recortar_transiciones(nueva)
        p["seq"] = nueva
        recort.append(nrec)
        rep.append((rell, malos))
        Q0.append(q0)
    Q = [calidad(p["seq"]) for p in pl]
    for q, r in zip(Q, rep):
        q["rell"] = sum(r[0]) / T          # fraccion de cuadros que salieron de interpolar

    # --- J con el menique arriba (se inserta una plantilla nueva justo antes de la primera J)
    nota_j = "no aplica"
    if not a.sin_j and not any(p.get("sintetica") == "J-hibrida" for p in pl):
        idx_j = [i for i, p in enumerate(pl) if p["gloss"].upper() == "J"]
        sep_j = [i for i in idx_j if pl[i].get("fuente") == "sep"]
        otras = [i for i in idx_j if i not in sep_j]
        if not sep_j:
            nota_j = "sin plantilla J del alfabeto SEP: no se fabrico"
        elif not otras:
            nota_j = "sin otra J de la que tomar el movimiento: no se fabrico"
        else:
            h_sep = Q[sep_j[0]]["dom"]
            ref = elegir_referencia_i(pl[sep_j[0]]["seq"], h_sep)
            fuente_mov = elegir(otras, Q, "amplio")
            if ref is None or fuente_mov is None:
                nota_j = "no hay mano 'I' limpia en la J del alfabeto o J amplia buena: no se fabrico"
            else:
                nueva_seq, h = construir_j_hibrida(pl[fuente_mov]["seq"], ref)
                if nueva_seq is None:
                    nota_j = "fallo la construccion (%s)" % h
                else:
                    P_all = [puntos20(f, h) for f in nueva_seq if f[OFF_PRES[h]] >= 0.5]
                    minr = min(rectitud(P, (17, 18, 19, 20)) for P in P_all)
                    nuevo = {"sign_id": pl[sep_j[0]]["sign_id"], "gloss": pl[sep_j[0]]["gloss"],
                             "espanol": pl[sep_j[0]]["espanol"], "seq": nueva_seq, "aspecto": 1.0,
                             "sintetica": "J-hibrida", "_seq_orig": nueva_seq, "_sin_verificar": True}
                    amp_fuente = Q[fuente_mov]["amp"]
                    pl.insert(idx_j[0], nuevo)
                    Q0.insert(idx_j[0], calidad(nueva_seq))
                    q_nuevo = calidad(nueva_seq)
                    q_nuevo["rell"] = 0.0
                    Q.insert(idx_j[0], q_nuevo)
                    rep.insert(idx_j[0], ([0, 0], [0, 0]))
                    recort.insert(idx_j[0], 0)
                    nota_j = (f"J fabricada: movimiento de la plantilla #{fuente_mov} (amplitud {amp_fuente:.0f} grados), "
                              f"mano de la J del alfabeto; menique recto >= {minr:.2f} en los {len(P_all)} cuadros con mano")
    print("J:", nota_j)

    # --- letras con un dedo mal estimado por la camara: plantilla fabricada de primera (Y, Z)
    notas_forma = {}
    if not a.sin_forma:
        for g, (marca_s, corr, porque) in FORMA_CORREGIDA.items():
            if any(p.get("sintetica") == marca_s for p in pl):
                continue                      # ya fabricada (el script se puede correr varias veces)
            idx_g = [i for i, p in enumerate(pl) if p["gloss"].upper() == g]
            sep_g = [i for i in idx_g if pl[i].get("fuente") == "sep"]
            if not sep_g:
                notas_forma[g] = "sin plantilla del alfabeto SEP: no se fabrico"
                continue
            src = pl[sep_g[0]]
            nueva_seq = construir_forma_corregida(src["seq"], corr)
            nuevo = {"sign_id": src["sign_id"], "gloss": src["gloss"], "espanol": src["espanol"], "seq": nueva_seq,
                     "aspecto": 1.0, "sintetica": marca_s, "_seq_orig": nueva_seq, "_sin_verificar": True}
            # la posicion y el cuerpo son los de la original (solo cambio la forma de los dedos)
            for t_, (x, y) in enumerate(zip(src["seq"], nueva_seq)):
                assert x[0:24] == y[0:24], f"cuerpo cambiado al fabricar {g}"
                for h in (0, 1):
                    assert x[OFF_LOC[h]:OFF_LOC[h] + 3] == y[OFF_LOC[h]:OFF_LOC[h] + 3], f"posicion cambiada al fabricar {g}"
            pos = idx_g[0]
            q_nuevo = calidad(nueva_seq)
            q_nuevo["rell"] = 0.0
            pl.insert(pos, nuevo)
            Q0.insert(pos, calidad(nueva_seq))
            Q.insert(pos, q_nuevo)
            rep.insert(pos, ([0, 0], [0, 0]))
            recort.insert(pos, 0)
            notas_forma[g] = f"{marca_s} fabricada de la plantilla del alfabeto SEP: {porque}"
    for g, n in notas_forma.items():
        print(f"{g}:", n)

    # --- 3: sin mano
    por_gloss = {}
    for i, p in enumerate(pl):
        por_gloss.setdefault(p["gloss"], []).append(i)
    quitar = set()
    unica_sin_mano = []
    for g, idx in por_gloss.items():
        for i in idx:
            if max(Q[i]["cov"]) < UMBRAL_SIN_MANO:
                if len(idx) > 1 and not a.sin_quitar:
                    quitar.add(i)
                else:
                    unica_sin_mano.append(i)
    # no quitar si eso deja a la sena sin plantillas
    for g, idx in por_gloss.items():
        if all(i in quitar for i in idx):
            for i in idx:
                quitar.discard(i)
            unica_sin_mano.extend(idx)

    # --- 4: reordenar dentro de las posiciones (slots) de cada sena
    n_tot = len(pl)
    nuevo_orden = list(range(n_tot))
    acciones = {}
    if not a.sin_reordenar:
        for g, idx in por_gloss.items():
            vivos = [i for i in idx if i not in quitar]
            if not vivos:
                continue
            primera = vivos[0]
            elegido = None
            motivo = ""
            fijos = [i for i in vivos if prioridad(pl[i]) > 0]
            if fijos:
                elegido = max(fijos, key=lambda i: (prioridad(pl[i]), -vivos.index(i)))
                motivo = ("plantilla fabricada " + pl[elegido]["sintetica"]) if prioridad(pl[elegido]) == 2 else "alfabeto SEP"
            else:
                crit = pref.get(g.upper())
                if crit:
                    elegido = elegir(vivos, Q, crit)
                    motivo = crit
                elif not es_buena(Q[primera]):
                    elegido = elegir(vivos, Q, "limpia")
                    motivo = "calidad"
            if elegido is not None and elegido != primera:
                resto = [i for i in vivos if i != elegido]
                orden = [elegido] + resto
                for slot, i in zip(vivos, orden):
                    nuevo_orden[slot] = i
                acciones[g] = (primera, elegido, motivo)

    salida = [nuevo_orden[s] for s in range(n_tot) if nuevo_orden[s] not in quitar]
    pl_nuevo = []
    for i in salida:
        p = pl[i]
        d = {"sign_id": p["sign_id"], "gloss": p["gloss"], "espanol": p["espanol"],
             "seq": [[round(v, DECIMALES) for v in fr] for fr in p["seq"]]}
        for k in ("aspecto", "fuente", "sintetica"):
            if k in p:
                d[k] = p[k]
        pl_nuevo.append(d)

    ruta_sal = a.salida or a.entrada
    if a.reporte:
        rep_csv = a.reporte
    else:
        # junto a los demas reportes (datasets_lsm/), NO dentro de assets/ para que no viaje en la app
        carpeta = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "datasets_lsm")
        if not os.path.isdir(carpeta):
            carpeta = os.path.dirname(os.path.abspath(ruta_sal))
            rep_csv = os.path.join(carpeta, "curacion_plantillas.csv")
        else:
            rep_csv = os.path.join(carpeta, "curacion_plantillas_" + time.strftime("%Y%m%d_%H%M%S") + ".csv")
    pos_nueva = {i: k for k, i in enumerate(salida)}
    # idx original = posicion en el archivo de entrada (la J fabricada no tiene)
    idx_entrada = {}
    c = 0
    for i, p in enumerate(pl):
        if p.get("_sin_verificar"):
            idx_entrada[i] = ""
        else:
            idx_entrada[i] = c
            c += 1
    with open(rep_csv, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["idx_original", "idx_nuevo", "gloss", "aspecto", "fuente", "cob_antes", "cob_despues",
                    "cuadros_malos_antes", "cuadros_rellenados", "cuadros_recortados", "estado", "nota"])
        for i, p in enumerate(pl):
            c0 = max(Q0[i]["cov"])
            c1 = max(Q[i]["cov"])
            estado = "quitada_sin_mano" if i in quitar else ("sin_mano_unica_regrabar" if i in unica_sin_mano else "ok")
            nota = ""
            if p.get("sintetica") == "J-hibrida":
                nota = "fabricada: " + nota_j
            elif p.get("sintetica"):
                nota = "fabricada: " + notas_forma.get(p["gloss"].upper(), p["sintetica"])
            if p["gloss"] in acciones and acciones[p["gloss"]][1] == i:
                nota = (nota + " | " if nota else "") + f"ahora es la primera ({acciones[p['gloss']][2]})"
            w.writerow([idx_entrada[i], pos_nueva.get(i, ""), p["gloss"], p.get("aspecto", ""), p.get("fuente", ""),
                        f"{c0:.2f}", f"{c1:.2f}", sum(rep[i][1]), sum(rep[i][0]), recort[i], estado, nota])

    # verificaciones: nada de cuerpo ni posicion real cambia
    for i, p in enumerate(pl):
        if p.get("_sin_verificar"):
            continue
        for t in range(T):
            ant, nue = p["_seq_orig"][t], p["seq"][t]
            assert ant[0:24] == nue[0:24], f"cuerpo cambiado en {i}:{t}"
            for h in (0, 1):
                if ant[OFF_PRES[h]] >= 0.5:
                    assert ant[OFF_LOC[h]:OFF_LOC[h] + 3] == nue[OFF_LOC[h]:OFF_LOC[h] + 3], f"posicion real cambiada en {i}:{t}"
            assert all(math.isfinite(v) for v in nue), f"valor no finito en {i}:{t}"
    for p in pl_nuevo:
        assert len(p["seq"]) == T and all(len(fr) == D for fr in p["seq"]), "forma de secuencia invalida"

    print(f"plantillas: {n0} -> {len(pl_nuevo)} | quitadas sin mano: {len(quitar)} | unicas sin mano: {len(unica_sin_mano)}")
    print(f"cuadros rellenados: {sum(sum(r[0]) for r in rep)} en {sum(1 for r in rep if sum(r[0]))} plantillas")
    n_rec = [(pl[i]["gloss"], recort[i]) for i in range(len(pl)) if recort[i]]
    print(f"transiciones recortadas en {len(n_rec)} letras del alfabeto: " + ", ".join(f"{g}({n})" for g, n in n_rec))
    print(f"senas con otra plantilla primera: {len(acciones)}")
    for g in ("G", "H", "J", "M", "N"):
        if g in acciones:
            print(f"  {g}: plantilla {acciones[g][0]} -> {acciones[g][1]} ({acciones[g][2]})")
        else:
            print(f"  {g}: sin cambio de primera (o no hay candidata)")
    if a.solo_reporte:
        print("reporte:", rep_csv)
        return

    # n_exportadas = cuantas salieron de la base antes de curar (aprobar_dataset.py lo usa para saber
    # si el archivo esta al dia). Va en el encabezado, antes de "plantillas".
    pkg_nuevo = {k: v for k, v in pkg.items() if k not in ("plantillas", "n_plantillas", "n_senas", "n_exportadas", "forma", "curado")}
    pkg_nuevo["n_plantillas"] = len(pl_nuevo)
    pkg_nuevo["n_senas"] = len({p["gloss"] for p in pl_nuevo})
    pkg_nuevo["n_exportadas"] = pkg.get("n_exportadas", n0)
    if not a.sin_iso or ya_iso:
        pkg_nuevo["forma"] = FORMA_ISO
    pkg_nuevo["curado"] = "v2"
    pkg_nuevo["plantillas"] = pl_nuevo
    if ruta_sal == a.entrada and not a.sin_respaldo:
        # el respaldo va a tools/_respaldo_antes_de_curar/, NO junto al archivo (assets/ viaja en la app)
        carpeta_resp = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_respaldo_antes_de_curar")
        os.makedirs(carpeta_resp, exist_ok=True)
        base = os.path.basename(os.path.dirname(os.path.dirname(os.path.abspath(a.entrada)))) + "_" + os.path.basename(a.entrada)
        resp = os.path.join(carpeta_resp, time.strftime("%Y%m%d_%H%M%S_") + base)
        shutil.copy2(a.entrada, resp)
        print("respaldo:", resp)
        viejos = sorted(glob.glob(os.path.join(carpeta_resp, "*_" + base)))[:-3]
        for v in viejos:
            try:
                os.remove(v)
            except OSError:
                pass
    tmp = ruta_sal + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(pkg_nuevo, f, ensure_ascii=False, separators=(", ", ": "))
    os.replace(tmp, ruta_sal)
    print("escrito:", ruta_sal, f"({os.path.getsize(ruta_sal):,} bytes)")
    print("reporte:", rep_csv)


if __name__ == "__main__":
    main()
