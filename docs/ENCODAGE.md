# Français et encodage, IQ-5.5.1

Le site, les guides, WinPE, la progression Windows, les outils IQ et les rapports emploient un français accentué. Les identifiants techniques et les noms de fichiers restent stables. Les anciens champs d’inventaire sont conservés pour rester compatibles avec les rapports déjà reçus ; leur libellé affiché est corrigé.

Les fichiers texte sont en UTF-8. Les scripts PowerShell portent un BOM UTF-8, nécessaire à leur lecture fiable dans Windows PowerShell 5.1. Leur transport vers Python et leurs écritures de journaux utilisent UTF-8. Le menu CMD utilise la page de codes 65001 ; la construction WinPE conserve ses octets UTF-8 au lieu de les convertir en ASCII. Les fichiers Lisez-moi sont également écrits en UTF-8.

Les PDF sont des fichiers binaires. Leur police Helvetica avec WinAnsi restitue les accents, les ligatures françaises, les guillemets français et les apostrophes. Les contrôles vérifient les octets et l’extraction du texte d’un rapport français.

La correction ne change pas les déclarations UTF-8 et les méthodes d’échappement déjà fonctionnelles du site. Les accents sont des caractères ordinaires dans les sources, sans entités HTML de remplacement. Les tirets longs sont remplacés par une ponctuation autorisée.

Avant publication : contrôle UTF-8 strict, recherche des séquences mal décodées, absence de caractères de remplacement, syntaxe PowerShell et essais navigateur. Les règles permanentes sont dans AGENTS.md et .editorconfig.
