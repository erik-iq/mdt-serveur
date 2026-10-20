# API et états

Les routes de console (`state`, `machines`, `assets`, `profiles`, `applications`, `bundles`, `deployments`) demandent `Authorization: Bearer <jeton administrateur>`. Les routes de l’agent demandent uniquement le jeton propre au déploiement. Aucun jeton ne passe en paramètre d’URL. Les réponses API sont `no-store`.

Après activation explicite du [mode interne](MODE-INTERNE.md), les routes administratives acceptent les requêtes sans jeton et refusent les origines navigateur externes. Les jetons agents restent temporaires et sont obtenus automatiquement ; ils ne sont pas demandés à l'opérateur. Le fichier `data-runtime.json` configure `internal_mode` et `automatic_windows` au lancement par `serve.py`. Les installations non activées conservent le parcours authentifié.

| Méthode / route | Fonction |
|---|---|
| GET `/health` | Disponibilité de l’API et de SQLite, sans readiness PXE |
| GET `/api/session` | Mode de connexion de la console et préparation automatique, sans secret |
| GET `/api/state` | Machines, fichiers, profils/settings, applications, bundles, options de personnalisation et 100 derniers déploiements, sans secrets |
| POST `/api/machines` | `{hostname, mac, description}` |
| POST `/api/assets` | `{filename, kind}` pour un fichier local déjà présent ; calcule SHA-256 |
| POST `/api/profiles` | `{name, asset_id, image_index, locale, windows_version, edition, settings}` ; settings facultatifs pour compatibilité 0.1 |
| POST `/api/applications` | `{name, version, asset_id, arguments, entry_point, install_mode, manufacturer}` ; fichier application EXE/MSI/ZIP |
| POST `/api/bundles` | `{name, description, application_ids}` ; IDs existants, sans doublons |
| POST `/api/deployments` | `{machine_id, profile_id, disk_number, confirmation, wizard_enabled}` ; renvoie jeton et éventuel code PXE une seule fois |
| POST `/api/boot/connect` | `{code, macs}` ; code PXE secret et MAC du poste autorisé, renvoie catalogue figé, plan et nouveau jeton agent |
| POST `/api/boot/discover` | Mode interne : `{macs}`, retrouve une seule autorisation interactive en attente, non expirée, puis renouvelle le jeton agent |
| GET `/api/agent/{id}/share-credentials` | Mode interne HTTPS : jeton agent valide requis ; connexion temporaire au partage de lecture géré, jamais incluse dans le plan ou le catalogue |
| GET `/api/deployments/{id}/events` | Journal ordonné, sans jetons |
| POST `/api/deployments/{id}/cancel` | Révoque immédiatement le jeton et demande l’arrêt aux points de contrôle |
| GET `/api/agent/{id}/plan` | Plan, identité MAC, disque, hash, index/locale, settings et fichiers des logiciels/fond d’écran sélectionnés |
| POST `/api/agent/{id}/configure` | `{profile_id, hostname, settings}` ; agent scoped, job queued avec wizard_enabled, sélection limitée au catalogue autorisé |
| POST `/api/agent/{id}/claim` | Réservation atomique ; une seule réservation autorisée |
| GET `/api/agent/{id}/image` | Téléchargement WIM authentifié ; le parcours WDS utilise la même image via SMB |
| POST `/api/agent/{id}/events` | `{status, progress, message}` ; progression monotone |
| GET `/boot/menu.ipxe` | Transport optionnel, 503 si les quatre fichiers de boot manquent |
| GET `/boot/assets/{id}` | Fichiers de démarrage uniquement ; WIM Windows, logiciels et fonds d’écran interdits |

États : `queued → running → staged / failed`, ou `queued / running → cancelled`. `staged` ne signifie pas que Windows a démarré. Un nouveau job peut être créé après un état terminal, avec une nouvelle autorisation d’effacement. Les jetons sont aléatoires et seul leur hash est conservé ; tout état terminal révoque leur utilisation. Une opération encore `queued/running` n’a pas d’expiration temporelle dans cette version : annuler les opérations abandonnées.

Transactions SQLite et index unique garantissent un seul job actif par machine. L’agent dispose aussi d’un mutex local pour empêcher deux processus sur le même poste. La MAC est un contrôle d’erreur, pas une attestation cryptographique : segmenter le réseau et protéger les jetons.

## Assistant interactif

`wizard_enabled` vaut **false par défaut dans l’API** pour préserver les anciens clients ; le formulaire console le coche par défaut. Quand il est activé, l’autorisation inclut un instantané de tous les profils, applications, bundles et fonds d’écran présents. De nouveaux éléments enregistrés ensuite ne sont pas utilisables par ce job. Les modifications sont acceptées uniquement avant `claim` ; le numéro du disque et la MAC restent fixés par l’administrateur.

Le code utilise 20 caractères aléatoires d’un alphabet de 32 caractères (100 bits), affichés par groupes de quatre. Seul son SHA-256 est stocké. Il expire après deux heures ; le job doit néanmoins être annulé s’il est abandonné. `boot/connect` exige le code et la MAC, puis renouvelle le jeton agent, invalidant le précédent. Une reconnexion reste possible avant la réservation ; `claim` désactive définitivement le code. Les états terminaux empêchent toute reconnexion. Ne pas journaliser les corps de ces requêtes au proxy.

`settings` comprend `keyboard`, `timezone`, `user_locale`, `registered_owner`, `organization`, `theme`, `wallpaper_asset_id`, `application_ids`, `bundle_ids`. Les claviers/fuseaux proposés sont retournés dans les options ; le thème vaut `unchanged`, `light` ou `dark`. Les applications ont un constructeur cible `all`, `hp` ou `lenovo`. Le filtrage matériel est réalisé dans WinPE puis revérifié au premier démarrage. Les IDs issus de bundles et de sélections directes sont dédupliqués.

Depuis IQ-4.3, `automatic_windows=true` active uniquement `unattended`. Les champs historiques `windows_update` et `store_update` restent acceptes pour compatibilite mais sont normalises a false dans les profils publics, plans et choix WinPE. La preparation les ignore meme dans une ancienne charge utile. `maintenance.json` et le rapport indiquent `manual` pour ces etapes. Les services et politiques de Windows ne sont pas desactives. Le plan expose `internal_mode` pour adapter le recapitulatif d effacement.

Les ZIP exigent un point d’entrée relatif EXE/MSI. Le mode `portable` est réservé aux ZIP, sans arguments : copie et raccourci ; Depuis IQ-4.5, HP Image Assistant est installe par WinGet au premier demarrage uniquement si `hpia` est coche, sans ZIP du serveur, puis execute en mode silencieux dans la finalisation SYSTEM : analyse et installation de tous les SoftPaq recommandes compatibles, sans commande de redemarrage Atelier. Le resultat et les codes des paquets sont joints au rapport ; les autres constructeurs sont ignores. Les EXE/MSI utilisés sont vérifiés par Authenticode sur le poste avant exécution. L’état `staged` inclut la préparation du bundle ; les résultats du premier démarrage sont écrits dans `C:\ProgramData\AtelierPXE\result.json`, avec remontée Windows et rapport dans la console pour les clients ATELIER-2.

Les assets sont immuables par convention, avec taille/date vérifiées côté serveur et SHA-256 vérifié dans WinPE. Un WIM dont le contenu change doit être enregistré sous un nouveau nom. Le serveur ne fournit pas de signatures d’éditeur ni de vérification antivirale des images ; utiliser les sources officielles et vérifier les médias en amont.

## Remontée Windows ATELIER-2

L’appel `POST /api/agent/{id}/claim` fournit également un `report_token`, distinct du jeton WinPE, et sa date `report_expires` (quatorze jours). Il est enregistré uniquement dans le dossier privé du poste. Ce jeton ne permet ni de lire les images/logiciels ni de modifier le disque ou un autre déploiement. Les appels WinPE restent révoqués à `staged`.

| Route | Autorisation et rôle |
| --- | --- |
| POST `/api/windows/{id}/progress` | Jeton de rapport ; état, progression et message Windows. |
| POST `/api/windows/{id}/report` | Jeton de rapport ; inventaire structuré, étapes et avertissements. Corps limité à 128 Kio. |
| GET `/api/deployments/{id}/report.pdf` | Administrateur ou mode interne ; PDF généré avec l’historique WinPE. |

`GET /api/state` expose `windows_status`, `windows_progress`, `windows_message`, `windows_updated_at` et `has_report` pour chaque déploiement, ainsi qu’une liste `reports` rattachée aux machines. Ces états Windows sont distincts des états WinPE. Une remontée terminale ne peut pas être remplacée par une ancienne progression « running ». Le renvoi d’un même rapport final est accepté, notamment après les tests matériels. Les identifiants de rapport ne sont jamais exposés dans cet état public administrateur.

`GET /health` conserve `version=0.2.0` et annonce `release=ATELIER-2`. Les guides intégrés sont servis à `/static/guide.html` et `/static/upgrade.html`.

## Mise à jour d’un logiciel ATELIER 2.1

`PUT /api/applications/{id}` accepte le même modèle que `POST /api/applications`. L’identifiant reste stable pour les références des bundles et profils. Le serveur refuse cette modification tant qu’une autorisation est `queued` ou `running`. Le nouvel asset doit déjà être enregistré et valide ; les anciens assets ne sont ni écrasés ni supprimés. La modification ne change pas les logiciels déjà copiés sur un poste `staged`. La synchronisation WinGet utilise cette route après validation du fichier et de son éditeur.

`GET /health` ajoute `revision=2.1`. Les XML/CSV détaillés sont générés localement dans IQ_ ; ils ne sont pas envoyés par l’API du PDF.


## Selection de logiciels IQ-4.5

`customization_options.software_packages` expose six valeurs : `vlc`, `reader`, `chrome`, `anydesk`, `hpia` et `lenovo_system_update`. `settings.winget_packages` conserve exactement la selection finale, y compris une liste vide ; aucune detection constructeur ne rajoute HPIA. Les nouveaux profils gardent les quatre logiciels usuels comme valeurs initiales, sans outil constructeur.

`customization_options.software_presets` fournit deux raccourcis : `hp` selectionne les quatre logiciels usuels et `hpia`, `lenovo` selectionne les quatre logiciels et `lenovo_system_update`. Les clients appliquent ces raccourcis aux cases puis transmettent la liste finale. HPIA non selectionne donne un etat `skipped` et ne lance pas de SoftPaq. Lenovo est installe silencieusement par WinGet sans ajout d un lancement automatique de ses mises a jour de pilotes.

## Archivage et nettoyage IQ-4.8

- POST /api/windows/{id}/report retourne accepted, deployment_id et sha256 des octets JSON recus.
- POST /api/windows/{id}/inventory/diagnostics accepte un ZIP de journaux strictement limites, 8 MiB compresses et 32 MiB extraits au maximum. Aucune extraction ni execution serveur. Les chemins, entrees dupliquees, liens ZIP, fichiers de configuration / identifiants et autres extensions sont refuses.
- POST /api/windows/{id}/cleanup-ready exige report, xml, csv et diagnostics (SHA-256 minuscules). Il utilise le jeton Windows du seul deploiement, exige un etat final et verifie le recu du rapport ainsi que les octets des fichiers serveur. Une absence ou divergence retourne 409 ; un jeton invalide / expire retourne 401.
- GET /api/deployments/{id}/inventory et /inventory/diagnostics exposent l archive seulement aux administrateurs de la console. Aucun jeton n est publie dans ces reponses.

Le client valide aussi les recus, les fichiers locaux et l arret des installateurs avant suppression. Les reponses cleanup-ready autorisent uniquement le nettoyage de son propre dossier prive, jamais une action WinPE ou un effacement de disque.
