# IQ Atelier 4 - bureau disponible et preparation en arriere-plan

Cette version unifie le site, WinPE et le suivi Windows en bleu/lilas. Le logo fourni a ete adapte sur fond transparent. Pour utiliser le PNG original sans adaptation, passer `-BrandLogoPath C:\chemin\logo.png` au script de mise a jour.

## Correctif graphique IQ-4.1

Le logo est limite a 40 x 40 pixels et place en haut a droite sur le site, WinPE et le suivi Windows. Le site lui donne aussi des dimensions HTML : une feuille de style absente ou ancienne ne peut plus afficher le PNG a sa taille d origine.

La feuille de style utilise un seul theme : fond clair, cartes blanches, texte bleu nuit, boutons bleus et degrade bleu `#D2E4F1` / lilas `#E9D9EA`. Les anciennes regles vert fonce ont ete retirees.

Chaque adresse CSS, JavaScript et logo contient une empreinte de son contenu. Les pages et ressources du site portent `Cache-Control: no-store`, pour eviter le melange nouveau HTML / ancien CSS lors d une mise a jour. `/health` confirme maintenant `ui_revision: IQ-4.3` ; la mise a jour controle ce marqueur avant de valider le demarrage.

Apres la mise a jour, ouvrir `https://192.168.99.250/?theme=IQ-4.3`. Pour WinPE et la preparation des prochains postes, utiliser l image reconstruite par le script de mise a jour. Les tests navigateur reproduisent le logo geant avec l ancien CSS puis verifient la correction sur ecran 1440, 1920 et mobile 390 pixels. Le rendu WinForms reste a valider sur Windows.

## Assistant et fiche ordinateur IQ-4.2

Les polices WinForms utilisent un constructeur explicitement type : cela evite une interpretation de la taille comme un style italique. Le titre est moins grand, sa description peut revenir a la ligne et la liste Windows ne repete plus les informations du profil. Les reponses JSON annoncent explicitement UTF-8 pour Windows PowerShell 5.1. Les donnees existantes sont conservees : un nom deja enregistre avec des caracteres incorrects doit etre corrige dans sa source.

Le nom propose dans WinPE est uniquement constitue des quatre derniers chiffres du SN, en conservant les zeros initiaux. Aucun prefixe ni nom de remplacement n est ajoute. Si le SN est absent, generique ou contient moins de quatre chiffres, le champ reste vide. **Completer le nom avant de continuer**, par exemple `8323` devient `ATELIER-8323` : le nom Windows valide doit commencer par une lettre et contenir au maximum 15 lettres, chiffres ou tirets. Le champ Prefixe et le bouton Recalculer sont retires.

La region et les formats sont proposes en `fr-CH`. Cela ne change pas la langue du WIM ni automatiquement le clavier. Proprietaire et organisation ne sont plus demandes. Le fond `Fond Atelier.png` ou `fon atelier.png` est selectionne par defaut quand il est disponible. La mise a jour enregistre ce fichier si elle le trouve dans `<data_dir>\artifacts` ; sinon elle affiche un avertissement. Elle ne cree pas de faux fond d ecran. Pour l ajouter ensuite : copier le PNG dans ce dossier, puis Profils Windows, Enregistrer un fichier, type Fond d ecran.

Dans Activite de deploiement, cliquer **Fiche ordinateur**, ou cliquer le nom dans **Parc machines**. La fiche regroupe identite materielle, licence, historique pagine, PDF, XML/CSV, tests, garantie connue et observations datees du technicien. Les observations sont conservees sur le serveur, independamment des rapports. Les tests et la garantie apparaissent apres utilisation de leurs outils et regeneration du rapport ; aucun resultat n est invente.

Chaque nouveau deploiement mesure l application DISM du WIM, les logiciels WinGet, la preparation de l outil constructeur, les mises a jour HP et la collecte XML/CSV. Ces mesures apparaissent dans la fiche et les nouveaux rapports PDF. Les anciennes mesures Windows Update restent visibles dans l historique. Les durees sont mesurees par chronometre dans le processus ; elles n incluent pas les periodes hors tension ni les attentes entre redemarrages. Une fin de mesure non recue reste signalee et les anciens deploiements n obtiennent pas de durees reconstituees. Les transmissions reutilisent les memes identifiants de mesure pour eviter les doublons.

La fiche utilise la MAC d enregistrement comme identite du poste. Un changement de carte reseau peut donc necessiter un rapprochement manuel ; le numero de serie du dernier rapport reste visible.

## Preparation HP et mises a jour manuelles IQ-4.3

Le ZIP officiel extrait de HP Image Assistant doit deja etre enregistre comme outil portable HP, avec `HPImageAssistant.exe` comme point d entree. Le serveur reutilise cette reference hors bundles ; le client telecharge l outil apres Windows, verifie empreinte et signature HP, puis l execute dans la tache SYSTEM. Sur un autre constructeur, cette etape est ignoree. Sur un HP sans outil, le resultat est A verifier, sans faux succes.

La commande HPIA utilise `/Operation:Analyze /Category:All /Selection:All /Action:Install /Silent /Noninteractive`, avec dossiers dedies `/ReportFolder` et `/SoftpaqDownloadFolder`. L analyse recherche les recommandations du modele et de la version Windows, puis les SoftPaq correspondants sont selectionnes et traites. All couvre pilotes, logiciels, BIOS et firmwares recommandes compatibles. Cela ne force pas un paquet incompatible, ni un BIOS protege par mot de passe. Les scripts Atelier ne demandent aucun redemarrage et n ajoutent pas de parametre de redemarrage. Le comportement interne de chaque SoftPaq reste celui de HP ; valider le parcours BIOS sur le modele avant usage en serie. Certains firmwares terminent leur installation au redemarrage manuel du technicien ; le flash peut ensuite declencher ses propres cycles.

La progression affiche le traitement HP et sa duree reelle, sans inventer de pourcentage par paquet. Les codes retour HPIA et les resultats de remediation des rapports JSON/XML sont conserves. Les rapports natifs sont dans `C:\IQ_\Rapports\HPImageAssistant`, les telechargements dans `C:\ProgramData\AtelierPXE\HP-SoftPaqs`, et le resultat resumant l execution dans `C:\ProgramData\AtelierPXE\hpia-result.json`. Le PDF et la fiche du site recoivent les etats et erreurs SoftPaq disponibles.

Une passe HP au maximum est lancee automatiquement. Un resultat termine est reutilise pour les reprises de rapport. Une execution interrompue ou depassant 45 minutes est signalee A verifier : aucun installateur ou flash n est tue, et aucune seconde installation HP n est lancee automatiquement. Verifier les processus et le rapport HP avant une intervention manuelle ; garder le poste alimente pendant un flash. Le code 256 signifie aucune recommandation ; un modele non pris en charge ou des SoftPaq en echec ne sont pas declares installes.

Reference des parametres et limitations par version : [guide HP Image Assistant](https://ftp.ext.hp.com/pub/caps-softpaq/cmit/whitepapers/HPIAUserGuide.pdf). Les tests de cette revision simulent HPIA sous Linux et ne valident pas les flashs BIOS ou les paquets HP reels.

## Ce qui change

- Le site contient Vue d ensemble, Parc machines et Profils Windows. Les pages Infrastructure PXE et Logiciels & bundles sont retirees.
- WinPE cree automatiquement la demande du poste. Le choix de Windows Pro/Famille et la confirmation du disque restent sur le poste.
- Le premier demarrage enregistre une tache de preparation puis rend la main a Windows. Les logiciels WinGet et les diagnostics tournent apres l ouverture du bureau. L animation Windows de premiere connexion est desactivee ; les operations natives obligatoires du premier demarrage doivent tout de meme se terminer.
- La fenetre de suivi est reductible. Aucune console PowerShell visible n est necessaire.
- Windows Update et Microsoft Store ne sont plus recherches ni actualises par la preparation, meme si un ancien profil contient encore leurs options actives. Le rapport indique Manuel, jamais A jour sans verification. Les services et politiques natifs Windows restent en place ; le technicien lance ses mises a jour depuis Parametres et la bibliotheque Store.
- HP Image Assistant analyse le HP, selectionne toutes les recommandations compatibles et installe les SoftPaq en arriere-plan. Le bureau reste disponible. L ancienne ouverture automatique de sa fenetre est retiree ; le raccourci manuel est conserve.
- Aucun redemarrage demande par Atelier. Les codes de redemarrage HPIA et SoftPaq sont remontes dans le suivi et le rapport. Une fois les installations terminees, le technicien redemarre manuellement. Les relances de la tache finale servent uniquement a transmettre le rapport.
- Un seul inventaire technique final est collecte apres les logiciels et les mises a jour HP. Les reprises de transmission reutilisent les fichiers existants.
- Les sources des scripts et les textes de l interface sont en ASCII sans accents. Les donnees collectees restent en UTF-8 : les vrais noms du materiel et les valeurs d inventaire ne sont pas translitteres.

## Verification de l image et vitesse

Le SHA-256 complet du WIM reste calcule lors de son enregistrement sur le serveur. Le serveur refuse un fichier dont la taille ou la date ont change. WinPE ne relit plus la totalite du WIM pour recalculer son SHA-256 avant chaque installation : cela evite un parcours reseau de plusieurs gigaoctets avant DISM.

WinPE controle encore le fichier et sa taille, l index, l architecture x64, l edition, la langue, la MAC, l UEFI et le disque cible. Un verrou de lecture empeche la modification du WIM durant son utilisation. DISM conserve `/CheckIntegrity /Verify` pendant l application.

**Limite :** ces controles ne prouvent plus a chaque deploiement que tous les octets correspondent a l empreinte enregistree. Une image alteree conservant sa taille/date pourrait passer le controle initial ; DISM ne remplace pas une comparaison cryptographique complete. Conserver les droits d ecriture du partage limites aux administrateurs et reenregistrer une image apres tout remplacement. Le gain depend de la taille du WIM, du disque et du reseau.

## Dossier IQ

| Dossier | Contenu |
| --- | --- |
| `C:\IQ_\Diagnostics` | Son, webcam, clavier, batterie et resultats |
| `C:\IQ_\Licence` | Etat de l activation Windows |
| `C:\IQ_\Rapports` | Rapport-Deploiement.pdf, JSON, et Generer-Rapport.cmd |
| `C:\IQ_\Inventaire` | Export-Inventaire.cmd pour regenerer et transmettre XML/CSV |
| `C:\IQ_\Garantie` | Outil de verification et dates confirmees sur le portail constructeur |
| `C:\IQ_\Personnalisation` | Fond d ecran |

Les XML/CSV sont sur `.250` dans `<data_dir>\inventaires\NOM-DU-PC\ID-DEPLOIEMENT`. Dans Activite de deploiement, cliquer **Dossier inventaire** pour copier le chemin serveur ou telecharger les deux fichiers. Le PDF est egalement disponible sur la ligne du poste. Les anciens resultats connus sont deplaces dans leur categorie lors de la preparation du dossier ; les fichiers inconnus sont conserves. L organisation des machines deja deployees ne change pas sans execution des nouveaux scripts.

## Mettre a jour DEPLOY-01 (.250)

Executer la commande fournie dans la conversation dans **Windows PowerShell 5.1 administrateur sur DEPLOY-01**. Elle telecharge une revision precise et appelle `scripts\Upgrade-Atelier4.ps1`. Ne pas utiliser une archive de `main`, qui peut etre plus ancienne.

Le script retrouve l installation par sa tache planifiee, sauvegarde code/configuration et SQLite, installe la revision 4, active le parcours automatique, synchronise les editions du WIM, reconstruit WinPE avec les pilotes detectes puis l importe dans WDS sous **Atelier PXE - ATELIER-4 - date**. Les nouvelles dependances graphiques et le lanceur en arriere-plan sont inclus dans le WIM. Un simple remplacement du site ne suffit pas.

Exemple avec chemins explicites, depuis la nouvelle archive extraite :

```powershell
& .\scripts\Upgrade-Atelier4.ps1 `
    -InstallPath 'C:\AtelierPXE\console' `
    -OutputRoot 'D:\AtelierPXE' `
    -TrustedRootCertificate 'C:\AtelierPXE\certs\AtelierPXE-lab.cer' `
    -DriversPath 'D:\AtelierPXE\Drivers\WinPE-x64'
```

L archive ne fournit pas de WIM preconstruit : l ADK, les pilotes et le certificat public du serveur sont utilises pour le produire sur Windows. Ne pas interrompre le montage/enregistrement de DISM. Le chemin exact de `media\sources\boot.wim` est affiche a la fin. Les anciens WinPE sont refuses par la console avant tout effacement.

## Nettoyage du serveur

Apres construction et import verifies de la nouvelle image, les anciennes images WDS **Atelier** et leurs anciens dossiers de construction WinPE sont supprimes. Les images MDT restent independantes.

Le nettoyage complementaire traite uniquement les dossiers temporaires de mise a jour identifiables par leur nom et leur contenu (`Atelier-2/3/4-<guid>`, `Maj-Atelier2/3/4-<guid>`), ainsi que les anciennes sauvegardes identifiees. Il conserve au moins les trois sauvegardes les plus recentes par dossier de sauvegardes, les dossiers de moins d une heure, les chemins actifs/proteges et les dossiers contenant des liens. L installation courante, ses donnees, la nouvelle image, les pilotes, certificats et contenus inconnus sont conserves. Les fichiers de logiciels historiques encore references dans la base ne sont pas supprimes automatiquement. Journal : `<data_dir>\cleanup\nettoyage-date.json`.

Pour voir la selection avant un nettoyage manuel, fournir le vrai dossier d installation :

```powershell
& 'C:\AtelierPXE\console\scripts\Clear-AtelierObsolete.ps1' `
    -InstallPath 'C:\AtelierPXE\console' -WhatIf
```

`-WhatIf` ne supprime rien et n ecrit aucun journal. La mise a jour complete effectue deja le nettoyage apres ses controles.

## Verifier apres mise a jour

1. Recharger le site avec Ctrl+F5 : logo IQ, theme bleu/lilas, trois pages.
2. Demarrer un poste de test UEFI sur ATELIER-4 ; choisir edition, nom et disque puis confirmer.
3. Retirer le demarrage PXE prioritaire apres application : demarrer sur le disque Windows.
4. Verifier l arrivee au bureau et la progression reductible pendant WinGet.
5. Verifier `C:\IQ_\Rapports\Rapport-Deploiement.pdf`, les categories IQ et les XML/CSV sur .250.
6. Verifier le resultat HP Image Assistant, les SoftPaq et un eventuel redemarrage manuel. Windows Update et Microsoft Store doivent etre marques Manuel dans le rapport.

Journaux Windows : `C:\ProgramData\AtelierPXE\first-logon.log`, `maintenance.log`, `progress.json`, `reporting.log`, `software-logs`. Journaux du serveur : `<data_dir>\logs\console.log`. Le demarrage rapide Windows reste desactive a chaque deploiement ; le Fast Boot du BIOS est un reglage distinct.

## Pistes utiles pour la suite

- Actualiser regulierement le WIM Windows avec les mises a jour deja integrees : cela reduit le travail a effectuer sur chaque poste, sans supprimer les correctifs de securite.
- Preparer un cache local des pilotes par modele, avec validation et date de version, pour raccourcir les passages HP Image Assistant et Lenovo.
- Ajouter un etat Pret pour remise qui exige rapport disponible, activation verifiee et tests materiels valides, avec les points restants visibles.

Les tests automatises utilisent des images et services simules. Un deploiement reel, les pilotes et l OOBE doivent etre verifies sur un poste Windows de laboratoire.

## Comment preparer un WIM Windows a jour

Cette procedure est une proposition de maintenance. La mise a jour IQ-4.2 ne modifie pas votre WIM Windows et ne programme pas de maintenance automatique des images.

Le principe est d installer une fois les correctifs dans une copie de l image, sur .250, au lieu de les reinstaller sur chaque ordinateur. Prevoir de l espace pour la copie, le montage et les fichiers temporaires. Les operations DISM se font sur Windows avec les outils compatibles avec la version cible.

1. Conserver le WIM actuel pour le retour arriere. Creer une copie avec un nouveau nom, par exemple `Windows11-2026-10.wim`. Ne jamais monter en ecriture une image en cours de deploiement.
2. Relever les index Pro et Famille avec DISM /Get-WimInfo, ainsi que la version, l architecture et les langues. Telecharger depuis le Catalogue Microsoft Update les paquets officiels correspondants ; verifier leurs prerequis. Selon la version, des mises a jour de pile de maintenance ou des mises a jour cumulatives de point de controle doivent etre ajoutees dans un ordre precis.
3. Monter chaque index utilise dans un dossier vide, ajouter les paquets avec DISM /Add-Package, puis enregistrer avec /Unmount-Image /Commit. Traiter Pro et Famille : actualiser seulement un index ne met pas les autres a jour. Ne pas utiliser /ResetBase pour cette premiere procedure, afin de conserver les possibilites de retrait de correctifs.
4. Tester les deux editions sur un poste de laboratoire : demarrage UEFI, edition et activation, reseau, pilotes, WinGet et rapport. Verifier aussi les correctifs restants dans Windows Update. Certaines mises a jour, les applications Store et les pilotes restent propres a chaque ordinateur.
5. Enregistrer le nouveau WIM sous son nouveau nom dans Atelier, puis creer les profils pointant vers les bons index. Conserver les anciens profils jusqu a validation et choisir les nouveaux pour les prochains deploiements. Ne pas simplement remplacer les octets du fichier deja reference : le controle de taille/date et l empreinte enregistree doivent correspondre au nouveau fichier.

On peut renouveler cette preparation chaque mois apres validation des correctifs. L objectif est de reduire fortement le telechargement et l installation repetes ; une courte verification Windows Update reste utile pour les correctifs parus apres la fabrication de l image. La reconstruction de WinPE concerne l assistant de deploiement : elle ne met pas a jour Windows dans le WIM d installation.
