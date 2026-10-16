# IQ Atelier 4 - bureau disponible et preparation en arriere-plan

Cette version unifie le site, WinPE et le suivi Windows en bleu/lilas. Le logo fourni a ete adapte sur fond transparent. Pour utiliser le PNG original sans adaptation, passer `-BrandLogoPath C:\chemin\logo.png` au script de mise a jour.

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
