# Règles de rédaction et d’encodage

Tous les fichiers texte doivent être en UTF-8 valide. Le français conserve ses accents, cédilles, ligatures et apostrophes. Les identifiants techniques restent en ASCII. Ne jamais supprimer les accents pour contourner un problème d’encodage, ni les remplacer par des entités HTML.

Les tirets cadratins et demi-cadratins sont interdits dans les textes, commentaires, documents, interfaces et rapports. Employer une virgule, un deux-points ou des parenthèses.

Les scripts PowerShell sont enregistrés en UTF-8 avec BOM pour Windows PowerShell 5.1. Préserver ce BOM lors des copies et des générations. Les fichiers JSON, HTML et JavaScript sont en UTF-8. Les menus CMD accentués utilisent la page de codes 65001 et sont écrits en UTF-8 sans BOM. Les PDF utilisent l’encodage de leur police, qui doit restituer les caractères français sans perte.

Ne pas modifier les déclarations de charset, en-têtes HTTP ou méthodes d’échappement d’une page dont le rendu fonctionne sans nécessité démontrée. Ne pas renommer les champs techniques, chemins ou identifiants pour corriger leur libellé visible.

Après toute modification, exécuter les contrôles de `tests/test_source_encoding.py`. Vérifier également le rendu réel des pages touchées et la syntaxe PowerShell si des scripts sont modifiés. Les erreurs d’encodage et les caractères de remplacement sont des défauts à corriger avant publication.
