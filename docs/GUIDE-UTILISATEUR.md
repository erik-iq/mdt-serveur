# Utiliser Atelier PXE

Atelier PXE installe Windows sur un ordinateur démarré par le réseau, prépare ses logiciels et produit un rapport de contrôle. Ce guide décrit le serveur déjà installé dans l’atelier et le parcours **ATELIER-2**. L’installation efface le disque choisi : sauvegarder les données avant de commencer.

## Comprendre les trois machines

| Élément | Rôle | Adresse ou emplacement |
| --- | --- | --- |
| DEPLOY-01 | Serveur des images Windows et de la console Atelier | `192.168.99.250` |
| Hôte Hyper-V | Ordinateur qui héberge les machines virtuelles | `192.168.99.253` |
| PC cible | Ordinateur à installer, physique ou VM `PC-TEST-PXE` | Son adresse MAC est enregistrée dans Atelier |

Ouvrir la console à **https://192.168.99.250**. En mode interne, elle s’ouvre sans jeton. Le réseau de l’atelier doit donc rester accessible aux personnes autorisées à déployer. Le projet utilise WDS pour démarrer une image WinPE personnalisée ; il applique ensuite le WIM avec DISM. Il ne requiert pas une séquence de tâches MDT.

**WinPE** est le petit Windows de démarrage qui affiche l’assistant d’installation. **WIM** est le fichier contenant les éditions de Windows. Un **profil** associe une édition du WIM à une langue et des réglages. Un **bundle** regroupe les logiciels à installer.

## Préparer un poste

1. Brancher le poste en Ethernet, sur secteur, au réseau de l’atelier. Utiliser un disque dont les données peuvent être effacées.
2. Dans **Parc machines**, enregistrer le nom du poste et la MAC de l’interface utilisée pour démarrer en PXE. La MAC d’un dock peut être différente de celle du PC.
3. Dans **Profils Windows**, vérifier les profils disponibles. Le choix Pro ou Famille dépend du contenu du WIM et de la licence du poste. Un choix d’édition ne crée pas de licence.
4. Dans **Logiciels et outils**, vérifier le bundle, les versions et le fond d’écran. Les applications HP sont réservées aux HP ; les applications Lenovo aux Lenovo.
5. Créer une **nouvelle autorisation de déploiement**, avec le bon poste, le profil initial, le numéro du disque et **Autoriser le choix du profil et des paramètres dans l’assistant PXE** coché. Une autorisation expire après deux heures si l’installation n’a pas commencé.

## Choisir Pro ou Famille

Le technicien prépare une fois les profils depuis les véritables métadonnées de l’image. Sur DEPLOY-01, en PowerShell administrateur :

```powershell
& 'C:\AtelierPXE\console\scripts\Sync-WindowsEditions.ps1'
```

Un profil existant pour ce WIM sert de modèle pour la langue, le bundle et le bureau. Le script ajoute uniquement les éditions Pro, Famille ou Famille unilingue présentes dans le WIM. Il ne télécharge et ne convertit aucune édition. Si Famille n’est pas proposée, fournir un WIM qui la contient. Ne pas deviner son index : les index varient selon le média Microsoft.

Créer ensuite une **nouvelle autorisation**, car une autorisation mémorise le catalogue disponible au moment de sa création. Dans WinPE, l’étape **Windows** propose les profils Pro/Famille disponibles. Sans la case de choix dans l’assistant, seul le profil autorisé est accessible.

## Installer Windows

1. Démarrer le PC en **UEFI IPv4 / réseau**. Dans Hyper-V, utiliser le démarrage réseau de la VM cliente.
2. Choisir la nouvelle image **Atelier PXE - ATELIER-2 - date**. Une image ancienne conserve ses anciens scripts.
3. L’assistant retrouve la nouvelle autorisation par la MAC. En mode interne, aucun code PXE ni mot de passe SMB n’est à recopier. S’il ne trouve rien, vérifier la MAC et l’autorisation, puis cliquer sur Connexion.
4. Choisir le profil Windows et vérifier le nom du PC, la région, le clavier, le fuseau, le bundle et le fond d’écran. Un numéro de série trop court ou générique impose un nom manuel.
5. Lire le récapitulatif, surtout l’identité et la capacité du disque. **Installer Windows efface les partitions du disque indiqué.**
6. Attendre la fin de WinPE. **Image appliquée / staged** signifie que les fichiers Windows et le démarrage sont prêts ; les logiciels et les mises à jour restent à exécuter.
7. Éteindre WinPE avec `wpeutil shutdown`. Placer le disque / Windows Boot Manager avant le réseau, puis redémarrer. Sur un PC physique, utiliser son menu de démarrage si nécessaire.

## Suivre la préparation dans Windows

Le premier démarrage prépare le bureau et les logiciels. La fenêtre de progression affiche leur nom. Les processus PowerShell d’arrière-plan sont masqués.

Windows Update affiche successivement **Recherche**, **Téléchargement** et **Installation**, avec les titres des mises à jour. La recherche n’expose pas de pourcentage fiable : la barre s’anime et indique une durée variable. Pendant le téléchargement et l’installation, le pourcentage représente l’étape en cours, pas le temps restant de tout le déploiement. Il peut repartir de zéro lors d’une nouvelle étape ou passe.

La première recherche et les grosses mises à jour cumulatives peuvent être longues. Laisser le PC sur secteur et connecté. Le service Windows Update configuré sur le poste est conservé, y compris WSUS. Les pilotes et les mises à jour facultatives ne sont pas sélectionnés par ce parcours. Des redémarrages automatiques sont annoncés deux minutes à l’avance. La reprise est limitée à cinq passes, quatre redémarrages et six tentatives ; un problème temporaire donne une nouvelle tentative quinze minutes plus tard.

Sur un HP compatible, le package portable **HP Image Assistant**, enregistré avec le point d’entrée `HPImageAssistant.exe`, s’ouvre après la maintenance Windows. Le technicien choisit alors les pilotes à installer. Son ouverture n’installe aucun pilote ou BIOS automatiquement. Un raccourci reste sur le bureau si une ouverture manuelle est nécessaire. La disponibilité des pilotes dépend de la prise en charge du modèle par HP Image Assistant.

Le démarrage rapide **Windows** est désactivé pour tous les nouveaux déploiements. Le réglage Fast Boot du BIOS/UEFI n’est pas modifié.

## Contrôler le poste dans C:\IQ_

| Outil ou fichier | Utilisation |
| --- | --- |
| `Test-Materiel.cmd` | Ouvre les tests du son, de la webcam et du clavier dans le navigateur. Autoriser la webcam, tester et confirmer chaque résultat. |
| `Tests-Materiel.json` | Résultats saisis par l’opérateur. « Non testé » ne signifie pas « conforme ». |
| `Test-Batterie.cmd` | Génère le rapport batterie ; une VM ou un PC fixe peut légitimement ne pas avoir de batterie. |
| `Verifier-Licence.cmd` | Actualise l’état d’activation Windows, sans modifier la licence. |
| `Rapport-Deploiement.pdf` | Inventaire, édition et activation Windows, logiciels, mises à jour, avertissements et résultats matériels disponibles. |
| `Generer-Rapport.cmd` | Régénère le PDF après les tests, la vérification de garantie ou les interventions manuelles, puis tente la transmission à Atelier. |
| `Transmission-Rapport.json` | `sent` : reçu par Atelier ; `pending` : PDF local conservé et envoi à reprendre. |
| `Verifier-Garantie.cmd` | Ouvre la vérification officielle du constructeur et permet de consigner les dates confirmées. |

Les lanceurs peuvent demander l’autorisation administrateur pour écrire dans le dossier technique. Le test caméra montre l’image localement, sans l’enregistrer. Le clavier est testé uniquement dans sa zone dédiée ; Fn et certains raccourcis Windows demandent une vérification manuelle. Le son doit être confirmé à l’oreille. Ces outils ne peuvent pas certifier automatiquement l’état physique des périphériques.

## Lire le rapport dans Atelier

Après la fin ou l’arrêt définitif de la préparation, le PDF local est créé dans `C:\IQ_`. Le poste transmet ses informations à la console. Dans **Activité de déploiement**, le bouton **Rapport PDF** apparaît ; il est aussi disponible sur la ligne du poste dans **Parc machines**.

La console distingue l’état WinPE et l’état Windows. **Terminé** concerne les opérations automatiques ; vérifier aussi les avertissements du PDF, l’activation, les périphériques et les pilotes. L’actualisation Microsoft Store est une demande à Windows : elle ne garantit pas que toutes les applications ont fini de se mettre à jour. Contrôler la bibliothèque du Store si nécessaire.

Si la console est momentanément indisponible, le PDF reste local et l’envoi est retenté toutes les quinze minutes. Le jeton de rapport est valable quatorze jours depuis le début du déploiement. Passé ce délai, conserver le PDF local ; une intervention du technicien est nécessaire pour un nouveau rattachement. Ne pas copier les fichiers d’identifiants du dossier ProgramData dans un compte rendu.

## Que faire en cas de problème

| Symptôme | Vérification |
| --- | --- |
| WinPE ne démarre pas | Démarrage UEFI, câble, DHCP/WDS et choix de la bonne image. |
| Réseau ou disque absent dans WinPE | Pilotes WinPE du modèle ; demander une reconstruction au technicien. |
| Pro/Famille manque | Édition présente dans le WIM, synchronisation des profils, puis nouvelle autorisation avec choix activé. |
| Mises à jour lentes | Phase affichée, titre de la mise à jour, connexion, heure du poste ; ne pas couper l’alimentation pendant l’installation. |
| Nouvelle tentative prévue | Laisser le poste connecté ; consulter `maintenance.log` si les tentatives se répètent. |
| À vérifier / échec | Lire le PDF et `C:\ProgramData\AtelierPXE\maintenance.log` ou `first-logon.log`. Ne pas effacer l’état pour relancer une boucle. |
| Pas de PDF dans Atelier | Vérifier le PDF local et `Transmission-Rapport.json`, puis lancer `Generer-Rapport.cmd`. Les anciens clients antérieurs à ATELIER-2 n’ont pas cette remontée. |
| Webcam refusée | Autorisation du navigateur, réglages de confidentialité Windows, cache, pilote. Ce refus ne prouve pas une panne. |

## Terminer la recette

Vérifier l’édition et l’activation Windows, le nom et le numéro de série, le Gestionnaire de périphériques, le son, la webcam, le clavier et la batterie si présente. Effectuer les mises à jour de pilotes voulues dans l’outil constructeur. Actualiser le rapport après les tests avec `Generer-Rapport.cmd`, puis vérifier son téléchargement depuis Atelier. Garder le PDF avec la fiche du poste.

Pour la mise à jour du serveur et la reconstruction WinPE, suivre [la procédure ATELIER-2](MISE-A-JOUR-ATELIER-2.md). Pour une installation neuve de l’infrastructure, utiliser [INSTALLATION.md](INSTALLATION.md).
