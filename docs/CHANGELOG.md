# Journal des modifications

## Veille des versions Windows, 22 octobre 2026

- Vérification quotidienne des versions stables de Windows 11 depuis Microsoft Release Health, avec contrôle manuel depuis le site.
- Affichage des versions observées, des nouvelles versions disponibles, des builds, des dates de disponibilité et de fin de support Famille et Pro.
- Dernier contrôle réussi conservé et clairement signalé comme ancien en cas d’erreur réseau ou de changement du format Microsoft.
- Accès au média officiel et parcours de préparation puis de validation ; aucune modification automatique des images de production.

## Correctif de nettoyage WDS, 22 octobre 2026

- Conversion des architectures numériques WDS vers les noms attendus par wdsutil.
- Conservation du code et du message natifs en cas de refus de suppression.
- Vérification de la disparition de chaque ancienne inscription avant nettoyage des dossiers.
- Un refus conserve les anciens dossiers et laisse la mise à jour se terminer avec un avertissement. Le nouveau WinPE déjà importé reste disponible.

## IQ-5.7, 22 octobre 2026

- Dépôt KB sur .250 avec recherche Microsoft, téléchargement, cache et accès HTTPS limité au déploiement demandeur.
- Nouvelle page Correctifs Windows : actualisation en ligne, contextes exacts, fichiers disponibles, tailles, empreintes et erreurs.
- Installation Windows et .NET après les logiciels et HPIA, sans recherche Windows Update sur le poste ni intégration préalable au WIM.
- Checkpoints avant chaque installation, contrôle après redémarrage, détection des correctifs déjà présents et conservation des vrais échecs.
- Actualisation quotidienne à 02:00 sur .250. Désactivation de la planification WIM lors du changement de méthode.
- Inclusion des résultats et journaux KB dans les diagnostics archivés avant nettoyage.

## IQ-5.6, 22 octobre 2026

- Redémarrage automatique de fin, point de reprise durable et contrôle des logiciels au nouveau démarrage, sans réinstallation.
- Fenêtre de bilan réouverte à la connexion, même après nettoyage du dossier privé. Une seule reconnexion automatique du compte de préparation.
- Succès en vert dans l’activité et archivage confirmé avant suppression des fichiers temporaires du poste. Les contrôles manuels absents ne créent plus d’avertissement.
- Retrait des profils Famille unilingue du catalogue, sans supprimer leurs historiques ni modifier le WIM de production. La synchronisation ne les recrée plus.
- Suppression du suffixe Test des profils ordinaires de production. Les véritables candidats de maintenance restent identifiés pour leurs tests.
- Stockage serveur affiché uniquement dans la vue globale, retrait des panneaux explicatifs inutiles.
- Correction du contrôle VLC : le nom de désinstallation natif « VLC media player » est conservé.

## IQ-5.5.1, 22 octobre 2026

- Français accentué dans le site, les messages WinPE, la progression Windows, les outils IQ et les guides.
- Suppression des tirets longs des sources et des documents.
- Scripts PowerShell enregistrés en UTF-8 avec BOM pour PowerShell 5.1. Transport UTF-8 vers Python et écritures des fichiers texte explicites.
- Menu de reprise WinPE en UTF-8, page de codes 65001, sans conversion destructive en ASCII.
- Rapports PDF avec libellés français et contrôle de l’extraction des accents et ligatures. Les clés techniques des inventaires déjà reçus restent compatibles.
- Règles permanentes dans AGENTS.md et .editorconfig, contrôles automatiques UTF-8 et typographiques.

La mise à jour de la console actualise le site. Reconstruire WinPE pour intégrer les scripts aux prochains déploiements. Les rapports historiques ne sont pas réécrits automatiquement.
