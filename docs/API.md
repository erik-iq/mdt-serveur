# API et états

Les routes `/api/state`, `/api/machines`, `/api/assets`, `/api/profiles` et `/api/deployments` demandent `Authorization: Bearer <jeton administrateur>`. Les routes de l’agent demandent uniquement le jeton propre au déploiement. Aucun jeton ne passe en paramètre d’URL. Les réponses API sont `no-store`.

| Méthode / route | Fonction |
|---|---|
| GET `/health` | Disponibilité de l’API et de SQLite, sans readiness PXE |
| GET `/api/state` | Machines, images, profils et 100 derniers déploiements, sans secrets |
| POST `/api/machines` | `{hostname, mac, description}` |
| POST `/api/assets` | `{filename, kind}` pour un fichier local déjà présent ; calcule SHA-256 |
| POST `/api/profiles` | `{name, asset_id, image_index, locale}` |
| POST `/api/deployments` | `{machine_id, profile_id, disk_number, confirmation}` ; renvoie un jeton une seule fois |
| GET `/api/deployments/{id}/events` | Journal ordonné, sans jetons |
| POST `/api/deployments/{id}/cancel` | Révoque immédiatement le jeton et demande l’arrêt aux points de contrôle |
| GET `/api/agent/{id}/plan` | Plan, identité MAC, disque, hash, index et locale |
| POST `/api/agent/{id}/claim` | Réservation atomique ; une seule réservation autorisée |
| GET `/api/agent/{id}/image` | Téléchargement WIM authentifié ; le parcours WDS utilise la même image via SMB |
| POST `/api/agent/{id}/events` | `{status, progress, message}` ; progression monotone |
| GET `/boot/menu.ipxe` | Transport optionnel, 503 si les quatre fichiers de boot manquent |
| GET `/boot/assets/{id}` | Fichiers de démarrage uniquement ; WIM Windows interdits |

États : `queued → running → staged / failed`, ou `queued / running → cancelled`. `staged` ne signifie pas que Windows a démarré. Un nouveau job peut être créé après un état terminal, avec une nouvelle autorisation d’effacement. Les jetons sont aléatoires et seul leur hash est conservé ; tout état terminal révoque leur utilisation. Une opération encore `queued/running` n’a pas d’expiration temporelle dans cette version : annuler les opérations abandonnées.

Transactions SQLite et index unique garantissent un seul job actif par machine. L’agent dispose aussi d’un mutex local pour empêcher deux processus sur le même poste. La MAC est un contrôle d’erreur, pas une attestation cryptographique : segmenter le réseau et protéger les jetons.

Les assets sont immuables par convention, avec taille/date vérifiées côté serveur et SHA-256 vérifié dans WinPE. Un WIM dont le contenu change doit être enregistré sous un nouveau nom. Le serveur ne fournit pas de signatures d’éditeur ni de vérification antivirale des images ; utiliser les sources officielles et vérifier les médias en amont.
