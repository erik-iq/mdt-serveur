# Passation Atelier PXE vers Claude ou un autre mainteneur

État de référence : **29 octobre 2026**. Cette passation résume le code publié et les décisions connues de la conversation de travail. Elle ne constitue ni une copie intégrale des discussions ni une confirmation de l’état actuel du serveur.

## Dépôt et versions

| Élément | Référence |
| --- | --- |
| Dépôt | `https://github.com/erik-iq/mdt-serveur` |
| Branche à reprendre | `codex/atelier-2` |
| Révision fonctionnelle | IQ-6.3 |
| Commit fonctionnel IQ-6.3 | `34a8799c7c2cb19fa707768f3e225a8c10700fe8` |
| Suivi des étapes et états contextualisés | IQ-6.2, commit `101e5bd3477b337c233a688ec648f8b6fd488841` |
| Version technique de l’application et du paquet | `0.2.0` |
| Famille du démarrage PXE | ATELIER-4 |

La passation et la documentation peuvent évoluer dans des commits ultérieurs sans changer IQ-6.3. Consulter le dernier commit de la branche. Ne pas repartir de la branche par défaut sans vérifier sa version : les développements suivis ici sont publiés sur `codex/atelier-2`.

## Environnement connu

Le serveur de déploiement est **DEPLOY-01**, adresse **192.168.99.250**, sous Windows Server 2025. Le code est habituellement installé dans `C:\AtelierPXE\console`, les données dans `D:\AtelierPXE\data`. `data-runtime.json`, sur le serveur, fournit les chemins et options réellement utilisés.

WDS sert le démarrage WinPE. L’assistant ouvre le partage SMB des images et contacte l’API Atelier. DISM applique l’index de l’édition sélectionnée ; BCDBoot prépare le démarrage UEFI. La préparation Windows utilise des scripts PowerShell et des tâches planifiées. Les interfaces graphiques nécessitent Windows ; le développement et une partie des tests sont possibles sur Linux.

Le poste HP utilisé dans les échanges récents est un EliteBook 840 G5. D’autres générations HP sont présentes dans les anciens guides. Les modèles des exemples et les inventaires de test ne définissent pas tout le parc réel.

## Décisions de l’utilisateur à conserver

- Plusieurs postes distincts peuvent être déployés simultanément. Les autorisations actives sont protégées par poste, pas par un verrou global du serveur.
- L’assistant doit s’ouvrir maximisé et s’adapter à la taille de l’écran ; éviter les titres et fenêtres de progression tronqués.
- La confirmation du disque reste locale dans WinPE. Le choix du profil et de l’édition doit rester cohérent avec le WIM.
- Le parcours actuel est : HPIA si sélectionné, logiciels, personnalisation et dossier IQ, finalisation, redémarrage et bilan. HPIA n’est pas relancé sans nécessité après une reprise.
- Les installations automatiques de KB et Windows Update ont été retirées à la demande de l’utilisateur. Les anciens outils restent disponibles pour compatibilité et usage manuel. Le Store reste manuel.
- Une préparation réussie doit pouvoir redémarrer automatiquement puis afficher son bilan après reprise. Une absence de résultat n’est pas une confirmation de réussite.
- Les rapports HPIA détaillés sont conservés dans IQ et transmis au site. La suppression du dossier de travail privé exige l’archivage confirmé côté serveur. Ne pas supprimer le dossier IQ permanent.
- La région et le clavier sont suisses français. Dans le mode interne, les réglages sont `fr-CH`, `100c:0000100c` et `W. Europe Standard Time`. La langue réelle du média et du profil peut être `fr-FR` ; ne pas inventer un média français suisse distinct.
- Le site conserve les modes clair, sombre et automatique. Le stockage n’est présenté que dans la vue globale.
- Pour les validations physiques, l’utilisateur préfère un nouveau déploiement aux anciens essais par clé USB. Ne pas présenter un déploiement supplémentaire comme déjà effectué.
- Le français doit rester accentué. UTF-8 de bout en bout, BOM UTF-8 dans les scripts PowerShell 5.1, aucun tiret cadratin ou demi-cadratin. Les identifiants techniques restent en ASCII.

Les constantes du parcours des nouveaux postes se trouvent notamment dans `scripts/Deploy.ps1` : `hpia_first=true`, `cached_windows_updates=false`, `kb_first=false`, `automatic_windows_update=false`, `final_restart=true`, `cleanup_after_reporting=true`. Les anciennes charges de préparation peuvent garder d’autres paramètres ; ne pas les confondre avec les nouveaux déploiements.

## Points d’entrée du code

| Besoin | Fichiers principaux |
| --- | --- |
| API, authentification, données et autorisations | `app/main.py` |
| Identité du poste et profils | `app/identity.py`, `app/customization.py` |
| Assistant WinPE et application de Windows | `scripts/Wizard.ps1`, `scripts/Deploy.ps1`, `scripts/Build-WinPE.ps1` |
| Première préparation Windows | `scripts/Start-Preparation.ps1`, `scripts/FirstLogon.ps1` |
| HPIA en premier, reprises et résultats HP | `scripts/Client-HpiaFirst.ps1`, `scripts/HP-ImageAssistant.ps1`, `scripts/HP-Reports.ps1` |
| Cache HP côté serveur et côté poste | `app/hp_repository.py`, `app/maintenance.py`, `scripts/HP-Repository.ps1`, `scripts/HP-ClientRepository.ps1` |
| Logiciels, personnalisation, dossier IQ | `scripts/Client-Software.ps1`, `scripts/Prepare-IQTools.ps1`, `scripts/Theme.ps1` |
| Redémarrage, bilan, transferts et nettoyage | `scripts/Maintenance.ps1`, `scripts/Reporting.ps1`, `scripts/New-DeploymentReport.ps1`, `scripts/Finalization.ps1` |
| Étapes explicites et historique | `app/phases.py`, `app/computers.py`, `scripts/Timings.ps1` |
| Statistiques des déploiements et du réseau | `app/statistics.py`, `app/network_statistics.py`, `scripts/Network-Measurement.ps1` |
| Interface Web | `app/static/index.html`, `app/static/app.js`, `app/static/style.css`, `app/static/theme.js`, `app/static/maintenance.js`, `app/static/statistics.js` |
| Cache KB et veille des versions Windows | `app/windows_kb.py`, `app/windows_releases.py` |
| Installation et mise à jour de la console et WinPE | `scripts/Upgrade-Atelier4.ps1`, `scripts/Upgrade-Atelier3.ps1`, `scripts/Update-Console.ps1` |

## Interpréter les états et les mesures

Les étapes IQ-6.2 sont Image Windows, HPIA, Logiciels, Dossier IQ, Redémarrage et Bilan. Le serveur conserve le premier signal de début ; une actualisation de la page ne remet pas le compteur à zéro. Les étapes anciennes sans preuves restent inconnues. Le bilan final exige la réception du rapport, et le redémarrage terminé exige une confirmation de nouveau démarrage. Voir [les états](ETATS-ET-SUIVI.md).

Pour HP, distinguer la copie conservée sur le serveur, la dernière tentative d’actualisation et la source déclarée dans le bilan du poste. Une erreur CMSL liée à la version Windows peut empêcher la création d’un cache sans empêcher HPIA de travailler directement sur Internet. Ce repli suppose que le poste puisse joindre HP. Les paquets du cache avec analyse HP par Internet sont également distingués du dépôt CMSL hors ligne. Les contrôles de compatibilité et de signature restent actifs.

IQ-6.3 lit les compteurs de réception de l’interface IPv4 routée vers le partage, avant et après DISM. Le débit comprend le trafic connexe et les attentes de disque sur cet intervalle. Ce n’est ni un test Internet ni le débit exclusif du fichier WIM. Les interfaces SMB supplémentaires ne sont pas agrégées. La moyenne des postes est pondérée par leurs durées, sans l’annoncer comme un débit total du serveur. Les réceptions réellement nulles et les mesures absentes sont distinctes.

La vitesse de liaison est déclarée par la carte et peut être inconnue. Les changements visibles de route, de vitesse ou de compteur invalident la mesure. Un échec de collecte ou de transmission ne doit pas interrompre le déploiement. Les relevés sont idempotents et peuvent être retransmis depuis Windows. Voir [l’API](API.md) et [les statistiques réseau](GUIDE-UTILISATEUR.md#statistiques-réseau).

## État de validation et prochaine reprise

L’utilisateur a signalé une installation réussie après le retrait des KB automatiques. Cette confirmation antérieure ne prouve pas que les dernières évolutions IQ-6.2 et IQ-6.3 sont installées et validées sur le matériel.

Pour IQ-6.3, les tests ont couvert les contrats API, l’idempotence, les moyennes réseau pondérées, les compteurs simulés, les cas indisponibles, les reprises de transmission et les régressions de finalisation. Les scénarios navigateur ont vérifié la page Statistiques, les périodes, les erreurs réseau, l’échappement, le mode sombre et le mobile. Les 78 scripts PowerShell ont passé le contrôle de syntaxe. La collecte réseau native sous WinPE et la validation physique du prochain déploiement restent à confirmer.

À la reprise :

1. Vérifier la branche, les modifications locales et la dernière révision publiée.
2. Sur le serveur, identifier la console réellement installée et consulter `/health`. Le champ `ui_revision` doit annoncer IQ-6.3 si le code courant y est installé.
3. Vérifier l’image WinPE réellement importée dans WDS. Son titre et son manifeste `atelier-winpe.json` doivent correspondre à IQ-6.3 pour les nouveaux relevés réseau.
4. Après un déploiement demandé par l’utilisateur, consulter les étapes, la source HP, le bilan après redémarrage et les reçus d’archivage. Consulter aussi le débit reçu, la liaison et les éventuelles raisons de mesure indisponible.
5. Corriger le point établi par les journaux sans réactiver les anciennes étapes Windows Update ou KB par défaut.

La publication des sources, la mise à jour du site, la reconstruction WinPE et la validation physique sont quatre opérations distinctes. Ne pas annoncer comme effectué un contrôle qui n’a pas été réalisé.

## Données et conversations hors Git

Le dépôt contient le code et la documentation, pas les images Windows, les caches de pilotes, la base des déploiements, les inventaires de production, les certificats privés ou les identifiants. Les emplacements habituels incluent `D:\AtelierPXE\data`, `C:\AtelierPXE\console\data-runtime.json` et la configuration WDS. Les emplacements exacts sont à relever sur le serveur, sans publier les valeurs sensibles.

Les discussions ChatGPT originales doivent être exportées séparément depuis les contrôles de données de ChatGPT. Ne pas annoncer que cette passation transfère toutes les conversations. Pour Claude Code, ouvrir la bonne branche du dépôt et lire `CLAUDE.md`. Pour Claude sur le Web, fournir le dépôt ou les fichiers utiles, puis cette passation et les conversations pertinentes selon les possibilités de l’interface utilisée.

## Contrôles de développement

Installer les dépendances depuis `requirements-dev.txt` avec `constraints.txt`. Pour les tests graphiques, ajouter `requirements-browser.txt` et Chromium. `ATELIER_PWSH` désigne un exécutable PowerShell portable pour les tests compatibles. Les scripts destinés à Windows PowerShell 5.1 conservent leur BOM.

Exemples de contrôles ciblés :

```bash
.venv/bin/python -m pytest -q tests/test_source_encoding.py
.venv/bin/python -m pytest -q tests/test_statistics.py tests/test_network_statistics.py tests/test_phases.py
.venv/bin/python tests/browser_statistics.py
python3 scripts/package.py
```

Après modification des scripts Windows, exécuter `scripts/Test-PowerShellSyntax.ps1` et les tests PowerShell concernés. Un test ignoré faute de Windows ou de PowerShell n’est pas une validation native. La procédure de mise à jour serveur reste [ATELIER-4](ATELIER-4.md) ; les anciennes sections doivent être lues comme de l’historique.
