# API et états

Les routes de console (`state`, `machines`, `assets`, `profiles`, `applications`, `bundles`, `deployments`) demandent `Authorization: Bearer <jeton administrateur>`. Les routes de l’agent demandent uniquement le jeton propre au déploiement. Aucun jeton ne passe en paramètre d’URL. Les réponses API sont `no-store`.

| Méthode / route | Fonction |
|---|---|
| GET `/health` | Disponibilité de l’API et de SQLite, sans readiness PXE |
| GET `/api/state` | Machines, fichiers, profils/settings, applications, bundles, options de personnalisation et 100 derniers déploiements, sans secrets |
| POST `/api/machines` | `{hostname, mac, description}` |
| POST `/api/assets` | `{filename, kind}` pour un fichier local déjà présent ; calcule SHA-256 |
| POST `/api/profiles` | `{name, asset_id, image_index, locale, windows_version, edition, settings}` ; settings facultatifs pour compatibilité 0.1 |
| POST `/api/applications` | `{name, version, asset_id, arguments, entry_point, install_mode, manufacturer}` ; fichier application EXE/MSI/ZIP |
| POST `/api/bundles` | `{name, description, application_ids}` ; IDs existants, sans doublons |
| POST `/api/deployments` | `{machine_id, profile_id, disk_number, confirmation, wizard_enabled}` ; renvoie jeton et éventuel code PXE une seule fois |
| POST `/api/boot/connect` | `{code, macs}` ; code PXE secret et MAC du poste autorisé, renvoie catalogue figé, plan et nouveau jeton agent |
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

Les ZIP exigent un point d’entrée relatif EXE/MSI. Le mode `portable` est réservé aux ZIP, sans arguments : copie et raccourci, aucune exécution automatique de l’outil. Les EXE/MSI utilisés sont vérifiés par Authenticode sur le poste avant exécution. L’état `staged` inclut la préparation du bundle ; les résultats du premier démarrage sont écrits dans `C:\ProgramData\AtelierPXE\result.json`, sans retour automatique à la console dans cette version.

Les assets sont immuables par convention, avec taille/date vérifiées côté serveur et SHA-256 vérifié dans WinPE. Un WIM dont le contenu change doit être enregistré sous un nouveau nom. Le serveur ne fournit pas de signatures d’éditeur ni de vérification antivirale des images ; utiliser les sources officielles et vérifier les médias en amont.
