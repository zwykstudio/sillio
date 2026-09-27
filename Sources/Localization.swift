// Langue de l'interface : français si c'est la langue préférée du système, anglais sinon.
//
// Chaque texte est écrit sur place, en paire : tr("Record", "Enregistrer"). Pas de fichier de
// traduction à tenir à jour à part, et le même mécanisme sert à l'app et au moteur
// (le moteur est aussi compilé dans le CLI, qui n'a pas de dossier .lproj où chercher des .strings).

import Foundation

enum Language {
    /// Seule la première langue compte : un Mac en allemand puis français reçoit l'anglais.
    /// (Foundation choisirait le français en descendant la liste ; ce n'est pas voulu.)
    /// Respecte aussi la langue choisie pour l'app seule dans
    /// Réglages Système › Général › Langue et région › Applications.
    /// Le CLI le force à false : il parle toujours anglais.
    static var isFrench: Bool = {
        guard let first = Locale.preferredLanguages.first else { return false }
        return Locale(identifier: first).language.languageCode == .french
    }()
}

/// Le texte dans la langue de l'interface.
func tr(_ english: String, _ french: String) -> String {
    Language.isFrench ? french : english
}
