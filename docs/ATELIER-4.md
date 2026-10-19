# IQ Atelier 4 - bureau disponible et preparation en arriere-plan

Cette version unifie le site, WinPE et le suivi Windows en bleu/lilas. Le logo fourni a ete adapte sur fond transparent. Pour utiliser le PNG original sans adaptation, passer `-BrandLogoPath C:\chemin\logo.png` au script de mise a jour.

## Correctif graphique IQ-4.1

Le logo est limite a 40 x 40 pixels et place en haut a droite sur le site, WinPE et le suivi Windows. Le site lui donne aussi des dimensions HTML : une feuille de style absente ou ancienne ne peut plus afficher le PNG a sa taille d origine.

La feuille de style utilise un seul theme : fond clair, cartes blanches, texte bleu nuit, boutons bleus et degrade bleu `#D2E4F1` / lilas `#E9D9EA`. Les anciennes regles vert fonce ont ete retirees.

Chaque adresse CSS, JavaScript et logo contient une empreinte de son contenu. Les pages et ressources du site portent `Cache-Control: no-store`, pour eviter le melange nouveau HTML / ancien CSS lors d une mise a jour. `/health` confirme maintenant `ui_revision: IQ-4.2` ; la mise a jour controle ce marqueur avant de valider le demarrage.

Apres la mise a jour, ouvrir `https://192.168.99.250/?theme=IQ-4.2`. Pour WinPE et la preparation des prochains postes, utiliser l image reconstruite par le script de mise a jour. Les tests navigateur reproduisent le logo geant avec l ancien CSS puis verifient la correction sur ecran 1440, 1920 et mobile 390 pixels. Le rendu WinForms reste a valider sur Windows.

## Assistant et fiche ordinateur IQ-4.2

Les polices WinForms utilisent un constructeur explicitement type : cela evite une interpretation de la taille comme un style italique. Le titre est moins grand, sa description peut revenir a la ligne et la liste Windows ne repete plus les informations du profil. Les reponses JSON annoncent explicitement UTF-8 pour Windows PowerShell 5.1. Les donnees existantes sont conservees : un nom deja enregistre avec des caracteres incorrects doit etre corrige dans sa source.

Le nom propose dans WinPE est uniquement constitue des quatre derniers chiffres du SN, en conservant les zeros initiaux. Aucun prefixe ni nom de remplacement n est ajoute. Si le SN est absent, generique ou contient moins de quatre chiffres, le champ reste vide. **Completer le nom avant de continuer**, par exemple `8323` devient `ATELIER-8323` : le nom Windows valide doit commencer par une lettre et contenir au maximum 15 lettres, chiffres ou tirets. Le champ Prefixe et le bouton Recalculer sont retires.

La region et les formats sont proposes en `fr-CH`. Cela ne change pas la langue du WIM ni automatiquement le clavier. Proprietaire et organisation ne sont plus demandes. Le fond `Fond Atelier.png` ou `fon atelier.png` est selectionne par defaut quand il est disponible. La mise a jour enregistre ce fichier si elle le trouve dans `<data_dir>\artifacts` ; sinon elle affiche un avertissement. Elle ne cree pas de faux fond d ecran. Pour l ajouter ensuite : copier le PNG dans ce dossier, puis Profils Windows, Enregistrer un fichier, type Fond d ecran.

Dans Activite de deploiement, cliquer **Fiche ordinateur**, ou cliquer le nom dans **Parc machines**. La fiche regroupe identite materielle, licence, historique pagine, PDF, XML/CSV, tests, garantie connue et observations datees du technicien. Les observations sont conservees sur le serveur, independamment des rapports. Les tests et la garantie apparaissent apres utilisation de leurs outils et regeneration du rapport ; aucun resultat n est invente.

Chaque nouveau deploiement mesure l application DISM du WIM, les logiciels WinGet, la preparation des outils constructeur, Windows Update et la collecte XML/CSV. Ces mesures apparaissent dans l historique de la fiche et les nouveaux rapports PDF. Le temps de preparation de HP Image Assistant ne mesure pas l installation manuelle des pilotes dans son interface. Les durees sont mesurees par chronometre dans le processus ; elles n incluent pas les periodes hors tension ni les attentes entre redemarrages. Une fin de mesure non recue reste signalee et les anciens deploiements n obtiennent pas de durees reconstituees. Les transmissions reutilisent les memes identifiants de mesure pour eviter les doublons.

La fiche utilise la MAC d enregistrement comme identite du poste. Un changement de carte reseau peut donc necessiter un rapprochement manuel ; le numero de serie du dernier rapport reste visible.

## Ce qui change

- Le site contient Vue d ensemble, Parc machines et Profils Windows. Les pages Infrastructure PXE et Logiciels & bundles sont retirees.
- WinPE cree automatiquement la demande du poste. Le choix de Windows Pro/Famille et la confirmation du disque restent sur le poste.
- Le premier demarrage enregistre une tache de preparation puis rend la main a Windows. Les logiciels WinGet et les diagnostics tournent apres l ouverture du bureau. L animation Windows de premiere connexion est desactivee ; les operations natives obligatoires du premier demarrage doivent tout de meme se terminer.
- La fenetre de suivi est reductible. Aucune console PowerShell visible n est necessaire.
- Windows Update effectue une seule passe. La recherche asynchrone est limitee a 90 secondes : aucune mise a jour trouvee est annonce seulement si la recherche a reussi. Si le delai est depasse, une annulation de recherche est demandee et la verification est reportee avec un avertissement. Les telechargements et installations de mises a jour effectivement trouvees peuvent durer davantage ; le bureau reste disponible. Les politiques Windows Update/WSUS sont conservees.
- Aucune relance Windows Update dans 15 minutes, aucune succession de cinq passes, aucun redemarrage automatique impose pendant le travail. Un redemarrage requis apparait dans le suivi et le rapport. Une relance de la tache une fois terminee ne reprend que la transmission du rapport.
- Un seul inventaire technique final est collecte apres les logiciels et les mises a jour. Les reprises de transmission reutilisent les fichiers existants.
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
6. Si Windows Update est reporte, consulter l avertissement et lancer les mises a jour depuis Parametres plus tard. Le poste n est pas declare a jour sans recherche reussie.

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
