# API et états

Les routes de console (`state`, `machines`, `assets`, `profiles`, `applications`, `bundles`, `deployments`) demandent `Authorization: Bearer <jeton administrateur>`. Les routes de l’agent demandent uniquement le jeton propre au déploiement. Aucun jeton ne passe en paramètre d’URL. Les réponses API sont `no-store`.

Après activation explicite du [mode interne](MODE-INTERNE.md), les routes administratives acceptent les requêtes sans jeton et refusent les origines navigateur externes. Les jetons agents restent temporaires et sont obtenus automatiquement ; ils ne sont pas demandés à l'opérateur. Le fichier `data-runtime.json` configure `internal_mode` et `automatic_windows` au lancement par `serve.py`. Les installations non activées conservent le parcours authentifié.

| Méthode / route | Fonction |
|---|---|
| GET `/health` | Disponibilité de l’API et de SQLite, sans readiness PXE |
| GET `/api/session` | Mode de connexion de la console et préparation automatique, sans secret |
| GET `/api/maintenance/hp` | Modèles, plateformes, SoftPaq des dernières archives, versions CVA, demandes manquantes, historique et stockage ; `?fresh=true` invalide le cache de la vue |
| GET `/api/maintenance/windows` | Miroir des rapports WIM, étapes, durées, candidats et stockage ; aucun accès aux montages privés |
| POST `/api/maintenance/windows/check` | Recherche du catalogue en arrière-plan, versions détectées uniquement ; aucun MSU téléchargé ni DISM exécute ; 202 ou 409 si déjà en cours |
| GET `/api/maintenance/windows/runs/{run_id}/report` | Rapport JSON filtre en pièce jointe, autorisation administrateur ; aucun fichier arbitraire |
| GET `/api/state` | Machines, fichiers, profils/settings, applications, bundles, options de personnalisation et 100 derniers déploiements, sans secrets |
| POST `/api/machines` | `{hostname, serial_number, mac?, description} ; MAC seule encore acceptee pour les anciens clients` |
| POST `/api/assets` | `{filename, kind}` pour un fichier local déjà présent ; calcule SHA-256 |
| POST `/api/profiles` | `{name, asset_id, image_index, locale, windows_version, edition, settings}` ; settings facultatifs pour compatibilité 0.1 |
| POST `/api/applications` | `{name, version, asset_id, arguments, entry_point, install_mode, manufacturer}` ; fichier application EXE/MSI/ZIP |
| POST `/api/bundles` | `{name, description, application_ids}` ; IDs existants, sans doublons |
| POST `/api/deployments` | `{machine_id, profile_id, disk_number, confirmation, wizard_enabled}` ; renvoie jeton et éventuel code PXE une seule fois |
| POST `/api/boot/connect` | `{code, serial_number, macs?}` ; code PXE secret et SN du poste autorisé, renvoie catalogue figé, plan et nouveau jeton agent |
| POST `/api/boot/discover` | Mode interne : `{macs}`, retrouve une seule autorisation interactive en attente, non expirée, puis renouvelle le jeton agent |
| GET `/api/agent/{id}/share-credentials` | Mode interne HTTPS : jeton agent valide requis ; connexion temporaire au partage de lecture géré, jamais incluse dans le plan ou le catalogue |
| GET `/api/deployments/{id}/events` | Journal ordonné, sans jetons |
| POST `/api/deployments/{id}/cancel` | Révoque immédiatement le jeton et demande l’arrêt aux points de contrôle |
| GET `/api/agent/{id}/plan` | Plan, identité SN (MAC informative), disque, hash, index/locale, settings et fichiers des logiciels/fond d’écran sélectionnés |
| POST `/api/agent/{id}/configure` | `{profile_id, hostname, settings}` ; agent scoped, job queued avec wizard_enabled, sélection limitée au catalogue autorisé |
| POST `/api/agent/{id}/claim` | Réservation atomique ; une seule réservation autorisée |
| GET `/api/agent/{id}/image` | Téléchargement WIM authentifié ; le parcours WDS utilise la même image via SMB |
| POST `/api/agent/{id}/events` | `{status, progress, message}` ; progression monotone |
| GET `/boot/menu.ipxe` | Transport optionnel, 503 si les quatre fichiers de boot manquent |
| GET `/boot/assets/{id}` | Fichiers de démarrage uniquement ; WIM Windows, logiciels et fonds d’écran interdits |

États : `queued → running → staged / failed`, ou `queued / running → cancelled`. `staged` ne signifie pas que Windows a démarré. Un nouveau job peut être créé après un état terminal, avec une nouvelle autorisation d’effacement. Les jetons sont aléatoires et seul leur hash est conservé ; tout état terminal révoque leur utilisation. Une opération encore `queued/running` n’a pas d’expiration temporelle dans cette version : annuler les opérations abandonnées.

Transactions SQLite et index unique garantissent un seul job actif par machine. L’agent dispose aussi d’un mutex local pour empêcher deux processus sur le même poste. Le SN (ou la MAC pour les anciens clients) est un contrôle de cible, pas une attestation cryptographique : segmenter le réseau et protéger les jetons.

## Assistant interactif

`wizard_enabled` vaut **false par défaut dans l’API** pour préserver les anciens clients ; le formulaire console le coche par défaut. Quand il est activé, l’autorisation inclut un instantané de tous les profils, applications, bundles et fonds d’écran présents. De nouveaux éléments enregistrés ensuite ne sont pas utilisables par ce job. Les modifications sont acceptées uniquement avant `claim` ; le numéro de série identifie le poste ; le disque doit être confirmé dans WinPE.

Le code utilise 20 caractères aléatoires d’un alphabet de 32 caractères (100 bits), affichés par groupes de quatre. Seul son SHA-256 est stocké. Il expire après deux heures ; le job doit néanmoins être annulé s’il est abandonné. `boot/connect` exige le code et le SN du poste (MAC pour une ancienne fiche sans SN), puis renouvelle le jeton agent, invalidant le précédent. Une reconnexion reste possible avant la réservation ; `claim` désactive définitivement le code. Les états terminaux empêchent toute reconnexion. Ne pas journaliser les corps de ces requêtes au proxy.

`settings` comprend `keyboard`, `timezone`, `user_locale`, `registered_owner`, `organization`, `theme`, `wallpaper_asset_id`, `application_ids`, `bundle_ids`. Les claviers/fuseaux proposés sont retournés dans les options ; le thème vaut `unchanged`, `light` ou `dark`. Les applications ont un constructeur cible `all`, `hp` ou `lenovo`. Le filtrage matériel est réalisé dans WinPE puis revérifié au premier démarrage. Les IDs issus de bundles et de sélections directes sont dédupliqués.

Depuis IQ-4.3, `automatic_windows=true` active uniquement `unattended`. Les champs historiques `windows_update` et `store_update` restent acceptes pour compatibilité mais sont normalises a false dans les profils publics, plans et choix WinPE. La préparation les ignore même dans une ancienne charge utile. `maintenance.json` et le rapport indiquent `manual` pour ces étapes. Les services et politiques de Windows ne sont pas désactivés. Le plan expose `internal_mode` pour adapter le récapitulatif d’effacement.

Les ZIP exigent un point d’entrée relatif EXE/MSI. Le mode `portable` est réservé aux ZIP, sans arguments : copie et raccourci ; Depuis IQ-4.5, HP Image Assistant est installé par WinGet au premier démarrage uniquement si `hpia` est coché, sans ZIP du serveur, puis exécute en mode silencieux dans la finalisation SYSTEM : analyse et installation de tous les SoftPaq recommandés compatibles, sans commande de redémarrage Atelier. Le résultat et les codes des paquets sont joints au rapport ; les autres constructeurs sont ignorés. Les EXE/MSI utilisés sont vérifiés par Authenticode sur le poste avant exécution. L’état `staged` inclut la préparation du bundle ; les résultats du premier démarrage sont écrits dans `C:\ProgramData\AtelierPXE\result.json`, avec remontée Windows et rapport dans la console pour les clients ATELIER-2.

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

`PUT /api/applications/{id}` accepte le même modèle que `POST /api/applications`. L’identifiant reste stable pour les références des bundles et profils. Le serveur refuse cette modification tant qu’une autorisation est `queued` ou `running`. Le nouvel asset doit déjà être enregistré et validé ; les anciens assets ne sont ni écrasés ni supprimés. La modification ne change pas les logiciels déjà copiés sur un poste `staged`. La synchronisation WinGet utilise cette route après validation du fichier et de son éditeur.

`GET /health` ajoute `revision=2.1`. Les XML/CSV détaillés sont générés localement dans IQ_ ; ils ne sont pas envoyés par l’API du PDF.


## Sélection de logiciels IQ-4.5

`customization_options.software_packages` expose six valeurs : `vlc`, `reader`, `chrome`, `anydesk`, `hpia` et `lenovo_system_update`. `settings.winget_packages` conserve exactement la sélection finale, y compris une liste vide ; aucune détection constructeur ne rajoute HPIA. Les nouveaux profils gardent les quatre logiciels usuels comme valeurs initiales, sans outil constructeur.

`customization_options.software_presets` fournit deux raccourcis : `hp` sélectionne les quatre logiciels usuels et `hpia`, `lenovo` sélectionne les quatre logiciels et `lenovo_system_update`. Les clients appliquent ces raccourcis aux cases puis transmettent la liste finale. HPIA non sélectionné donne un état `skipped` et ne lance pas de SoftPaq. Lenovo est installé silencieusement par WinGet sans ajout d’un lancement automatique de ses mises à jour de pilotes.

## Archivage et nettoyage IQ-4.8

- POST /api/windows/{id}/report retourne accepted, deployment_id et sha256 des octets JSON reçus.
- POST /api/windows/{id}/inventory/diagnostics accepte un ZIP de journaux strictement limites, 8 MiB compresses et 32 MiB extraits au maximum. Aucune extraction ni exécution serveur. Les chemins, entrées dupliquees, liens ZIP, fichiers de configuration / identifiants et autres extensions sont refusés.
- POST /api/windows/{id}/cleanup-ready exige report, xml, csv et diagnostics (SHA-256 minuscules). Il utilise le jeton Windows du seul déploiement, exige un état final et vérifie le reçu du rapport ainsi que les octets des fichiers serveur. Une absence ou divergence retourne 409 ; un jeton invalide / expire retourne 401.
- GET /api/deployments/{id}/inventory et /inventory/diagnostics exposent l’archive seulement aux administrateurs de la console. Aucun jeton n’est publié dans ces réponses.

Le client valide aussi les reçus, les fichiers locaux et l’arrêt des installateurs avant suppression. Les réponses cleanup-ready autorisent uniquement le nettoyage de son propre dossier privé, jamais une action WinPE ou un effacement de disque.

## Dépôt HP IQ-4.9

- `GET /api/hp-repository` : état admin de l’agent CMSL, demandes et copies publiées ; aucun secret ni identité agent dans la réponse.
- `POST /api/hp-repository/refresh` : actualise les plateformes déjà connues, admin uniquement. Les demandes actives identiques sont regroupees.
- `POST /api/windows/{id}/hp-repository` : jeton Windows du déploiement avec HPIA sélectionné ; body strict `platform` (4 hex), `os` (`win10`/`win11`), `os_version`, `required_softpaqs` (200 IDs SP maximum). La première identité plateforme / Windows reste fixe pour ce déploiement. Aucun chemin, URL ou code PowerShell accepte.
- `GET /api/windows/{id}/hp-repository/{snapshot}.zip` : archive complète / compatible avec la demande enregistrée et le jeton Windows valide. URL relative de même origine ; transfert immuable et empreinte SHA-256 annoncee. Aucun accès via le jeton WinPE.
- `POST /api/hp-repository/worker/heartbeat`, `/worker/claim`, `/worker/jobs/{id}/finish` : secret local propre à l’agent CMSL. Le worker écrit une archive privee et ne publie que son identifiant ; le serveur valide les chemins, références, limites et calcule l’empreinte avant exposition.
- `POST /api/windows/{id}/inventory/hp_reports` : ZIP des rapports HP, fichiers texte autorisés uniquement, limites 32 Mo / 128 Mo developpes, 1024 entrées / 16 Mo chacune. Téléchargement admin sous `Rapports-HP.zip` via la route inventaire existante.
- `POST /api/windows/{id}/cleanup-ready` accepte une preuve `hp_reports` supplémentaire. Elle est obligatoire si le rapport annonce IQ-4.9 et la sélection contient HPIA. Les anciens clients gardent leur protocole de confirmation a quatre empreintes.

Le transport de rapports reste borne avant l’analyse et les fichiers HP sont servis uniquement en archive à télécharger. Le serveur n’exécute pas le HTML ou XML natif et ne decompresse aucun SoftPaq. Les snapshots sont conservés par trois versions et leurs locations temporaires de deux heures protegent les descripteurs emis aux postes.

## Identité des postes IQ-5.0

`POST /api/boot/discover` accepte `{release:"ATELIER-4", serial_number:"SN-DU-PC", macs:[]}`. Le SN BIOS normalise est la clé de rapprochement ; une MAC n’est pas obligatoire et peut être partagée entre plusieurs SN. Le même SN retourne la même fiche, même après changement de dock. Le plan expose `serial_number`. Les SN absents/generiques sont refusés par le nouvel assistant. Le SN n’est pas un secret ni une attestation cryptographique ; les jetons restent nécessaires pour agir sur un déploiement.

`POST /api/boot/connect` exige le SN d’une fiche liée au SN, même si une MAC correspond. Les codes, délais et rotations de jetons sont conservés. Le champ MAC reste un contrôle pour les anciennes fiches sans SN seulement ; une ancienne requête MAC ne prend jamais une fiche liée à un SN. Le site demande un SN pour l’enregistrement manuel. Les IDs et historiques SQLite restent conservés pendant la migration ; aucune ancienne fiche partagée n’est fusionnee sans preuve.


## Étapes explicites IQ-6.2

`POST /api/windows/{id}/progress` accepte les champs facultatifs couplés `stage` et `stage_status`. Les étapes Windows sont `hpia`, `software`, `iq`, `restart` et `summary`. Les états sont `running`, `reboot_pending`, `completed`, `failed`, `needs_attention` et `skipped`. L’ancien format sans ces champs reste accepté. Le jeton Windows du déploiement reste obligatoire.

Le serveur conserve la première réception comme début et la première clôture comme fin. Un signal en cours ne rouvre pas une étape clôturée. Une correction finale peut rectifier son résultat. Les dates du client ne sont pas acceptées comme horodatages d’étape.

`GET /api/deployments/{id}/pipeline`, réservé aux administrateurs, fournit les six étapes, leur état, leur message, leurs dates et `generated_at`. La vue globale expose aussi ce suivi. L’étape image repose sur les événements WinPE ; la réussite du bilan exige la réception du rapport Windows. Un résultat manquant devient `unknown` à la clôture, sans durée inventée.

Les réponses du dépôt HP ajoutent `cache_states`, indépendant des tâches de synchronisation. `ready` confirme une copie récente présente avec la taille enregistrée, `stale` une copie ancienne conservée, `unavailable` une copie absente ou non confirmée, `missing` aucune copie publiée. Ce contrôle ne remplace ni les recommandations du poste ni la vérification des empreintes par le client.


## Mesures réseau IQ-6.3

`POST /api/windows/{id}/network` utilise le jeton de rapport du seul déploiement. Il reçoit une mesure `source: winpe_image_rx`, `status: measured` ou `unavailable`, `application_status: completed` ou `failed`, `adapter_name`, `link_speed_bps` facultatif, `received_bytes`, `duration_seconds` et `reason`. Une mesure indisponible a des octets et une durée nuls au sens JSON (`null`), jamais des zéros de remplacement. Aucun horodatage du client ni adresse réseau supplémentaire n’est accepté.

La durée doit être positive et finie, les octets positifs ou nuls. La réception crée au plus une mesure par déploiement. La répétition de la même mesure est acceptée sans doublon ; une valeur différente retourne 409. Le client conserve le relevé local et le retransmet depuis Windows si nécessaire.

`GET /api/statistics/deployments` ajoute `network`, sur la même période de lancement. Les statistiques réseau concernent les applications d’image, indépendamment du bilan Windows. La moyenne en Mbit/s vaut `8 * somme(octets) / somme(secondes) / 1000000`, sans additionner les débits des postes simultanés. Les échecs d’application et les annulations sont exclus des moyennes. Les liaisons sous 1 Gbit/s sont comptées par application terminée dont la vitesse de liaison est connue, même si les compteurs ne sont pas disponibles. Les agrégats couvrent toute la période ; `samples` présente au plus les cinquante applications les plus récentes. Les mesures absentes restent distinctes des réceptions réellement mesurées à zéro octet.
