import 'perfiles.dart';

/// Guarda, para el resto de la sesión de la app, el perfil de quien usa
/// el teléfono y el de la persona con la que se está comunicando.
///
/// Se llena en [ProfileSelectionScreen] / [OtherPersonProfileScreen] (o
/// se preasigna a "ciego" cuando se detecta TalkBack, ver
/// BlindNarrator.activateTalkBackFlow) y lo usa ComunicarseScreen para
/// personalizar las instrucciones y el comportamiento según la
/// combinación exacta de perfiles (por ejemplo: una persona ciega
/// hablando con una sorda, o una muda hablando con una oyente).
///
/// [mine] y [mineKnowsLsm] además se persisten en el teléfono (ver
/// PerfilGuardado): son identidad y no hace falta volver a preguntarlos.
/// [other] y [otherKnowsLsm] NO se persisten nunca: cambian en cada
/// conversación.
class ConversationProfile {
  ConversationProfile._();

  /// Perfil de quien usa este teléfono.
  static ProfileType? mine;

  /// Perfil de la persona con la que se está comunicando.
  static ProfileType? other;

  /// Si [mine] es sordo/a o mudo/a, indica si quien usa el teléfono
  /// conoce Lengua de Señas Mexicana (solo tiene sentido cuando [mine]
  /// es uno de esos dos perfiles). Se llena en el refinamiento de
  /// ProfileSelectionScreen ("¿Cómo te puedo ayudar?" / "¿Conoces
  /// LSM?") — antes esta respuesta se preguntaba pero no se guardaba en
  /// ningún lado.
  static bool mineKnowsLsm = false;

  /// Si [other] es sordo/a o mudo/a, indica si conoce Lengua de Señas
  /// Mexicana (solo tiene sentido cuando [other] no es null).
  static bool otherKnowsLsm = false;

  /// Reinicia todo a los valores iniciales, incluido el perfil propio. Lo
  /// usa ProfileSelectionScreen al abrirse, porque ahí justamente se va a
  /// volver a elegir quién eres.
  ///
  /// Ojo: esto NO borra el perfil persistido en disco. Para eso está
  /// [PerfilGuardado.olvidar].
  static void reset() {
    mine = null;
    other = null;
    mineKnowsLsm = false;
    otherKnowsLsm = false;
  }

  /// Limpia solo los datos de la OTRA persona, conservando el perfil
  /// propio. Es el reinicio que corresponde cuando ya hay un perfil
  /// guardado y se empieza una conversación nueva saltándose la
  /// selección de perfil (ver PurposeScreen).
  static void resetOtro() {
    other = null;
    otherKnowsLsm = false;
  }
}

/// Perfiles que se comunican principalmente por señas (sordos y mudos),
/// a diferencia de ciego/a (que usa voz) u oyente (que usa voz y no
/// tiene ninguna discapacidad relacionada con esto).
bool esPerfilSordoOMudo(ProfileType? tipo) =>
    tipo == ProfileType.sordo || tipo == ProfileType.mudo;

/// Modo de comunicación resuelto a partir de la combinación de perfiles
/// guardada en [ConversationProfile]. Reemplaza al viejo booleano
/// `otherNeedsLsm`: con dos perfiles de cada lado (más si conocen LSM o
/// no), un solo booleano ya no alcanza para decidir qué pantalla
/// mostrar dentro de "Comunicarse".
enum ComunicacionModo {
  /// Uno de los dos (mine u other, el que sea sordo/a o mudo/a) conoce
  /// Lengua de Señas Mexicana y el otro es ciego/a u oyente (no firma):
  /// se muestra el avatar firmando lo que dice quien habla, Y una
  /// cámara para traducir a voz lo que firma quien sabe LSM (ver
  /// ComunicarseScreen._buildLsmVariant) — las dos direcciones en la
  /// misma pantalla, sin importar de qué lado del teléfono está cada
  /// quien.
  avatar,

  /// Texto y voz simple: se usa cuando al menos una de las dos personas
  /// no se comunica firmando (es ciega u oyente) y, del otro lado, no
  /// hace falta el avatar (persona oyente, muda, o sorda que no conoce
  /// LSM). Quien puede hablar dicta o escribe, y lo que llega se lee en
  /// voz alta o se muestra como texto según quién pueda oír.
  textoVoz,

  /// Las dos personas son sordas o mudas y al menos una de las dos no
  /// conoce LSM: se usa la cámara (el mismo reconocedor de señas de
  /// "Traducir señas") para traducir a texto lo que firma quien sí sabe,
  /// y la respuesta se escribe directamente porque ninguna de las dos
  /// puede oír una lectura en voz alta.
  camaraSenas,

  /// Las dos personas son sordas o mudas y ninguna de las dos conoce
  /// LSM: no hay nada que la cámara pueda traducir, así que se
  /// comunican escribiendo directamente, sin botones de voz (ninguna de
  /// las dos puede usarlos).
  soloTexto,

  /// Las dos personas son sordas o mudas y ambas conocen LSM: no
  /// necesitan la app para esto, pueden firmar directamente entre
  /// ellas.
  noNecesitaApp,
}

/// Decide el [ComunicacionModo] a partir de [ConversationProfile.mine] /
/// [other] y de si cada quien conoce LSM. No depende de si quien usa el
/// teléfono es ciego/a (eso solo agrega narración y control por voz
/// encima de la pantalla que corresponda — ver ComunicarseScreen — no
/// cambia qué pantalla es).
ComunicacionModo resolverComunicacionModo() {
  final mine = ConversationProfile.mine;
  final other = ConversationProfile.other;

  if (esPerfilSordoOMudo(mine) && esPerfilSordoOMudo(other)) {
    final mineKnows = ConversationProfile.mineKnowsLsm;
    final otherKnows = ConversationProfile.otherKnowsLsm;
    if (mineKnows && otherKnows) return ComunicacionModo.noNecesitaApp;
    if (!mineKnows && !otherKnows) return ComunicacionModo.soloTexto;
    return ComunicacionModo.camaraSenas;
  }

  // Al menos una de las dos personas no se comunica firmando (es ciega
  // u oyente): el avatar (con cámara para la dirección contraria, ver
  // ComunicarseScreen._buildLsmVariant) aplica si el lado que SÍ firma
  // (sordo o mudo) conoce LSM — sin importar si ese lado es "mine" (por
  // ejemplo, tú eres mudo/a y sabes LSM, hablando con alguien ciego) u
  // "other" (tú eres ciego/a, hablando con alguien sordo/a que sabe
  // LSM): las dos combinaciones tienen exactamente la misma barrera que
  // resolver, solo cambia de qué lado del teléfono está cada quien.
  final bool haceFaltaAvatar =
      (esPerfilSordoOMudo(mine) && ConversationProfile.mineKnowsLsm) ||
          (esPerfilSordoOMudo(other) && ConversationProfile.otherKnowsLsm);
  return haceFaltaAvatar ? ComunicacionModo.avatar : ComunicacionModo.textoVoz;
}
