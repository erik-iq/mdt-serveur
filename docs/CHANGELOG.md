# Journal des modifications

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
