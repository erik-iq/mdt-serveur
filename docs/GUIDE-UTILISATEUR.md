# IQ Atelier - guide utilisateur

IQ Atelier installe Windows sur les ordinateurs de l atelier depuis le reseau. Le serveur de deploiement est DEPLOY-01, `192.168.99.250`. Le site permet de suivre les installations et retrouver leurs rapports. Consulter [le guide de mise a jour ATELIER-4](ATELIER-4.md) pour mettre le serveur et WinPE a niveau.

## Avant de commencer

Sauvegarder les donnees du poste : le deploiement efface toutes les partitions du disque choisi. Brancher l alimentation et un cable reseau. Le poste doit demarrer en UEFI. Verifier qu une image Windows et ses profils Pro/Famille sont disponibles dans Atelier.

## Installer un ordinateur

1. Allumer le poste et choisir son demarrage reseau UEFI/PXE dans le menu de demarrage du constructeur.
2. Choisir l image **Atelier PXE - ATELIER-4 - date**. L assistant IQ Atelier s ouvre. Le poste et sa demande apparaissent automatiquement sur le site ; aucune autorisation prealable n y est necessaire.
3. Choisir Windows Pro ou Famille. Cette edition doit correspondre a la licence du poste. Un profil correspond a un index precis du WIM Windows, pas a un fichier ISO monte arbitrairement.
4. Completer le nom du PC : seuls les quatre derniers chiffres du SN sont proposes, sans prefixe. Exemple : `8323` devient `ATELIER-8323`. Le nom doit commencer par une lettre, avec au maximum 15 lettres, chiffres ou tirets. Verifier le clavier et le fuseau ; la region et les formats sont proposes en `fr-CH`.
5. Choisir les logiciels WinGet : VLC, Adobe Reader, Chrome, AnyDesk. Ils seront installes silencieusement dans Windows. Le fond `Fond Atelier.png` est propose s il est enregistre sur le serveur ; le theme et le fond restent modifiables. Proprietaire et organisation ne sont plus demandes.
6. Lire le recapitulatif, choisir le bon disque en verifiant sa taille et son numero de serie. **Installer Windows** efface ce disque.
7. Attendre la fin de l application de l image. Redemarrer sur le disque local Windows, avec le demarrage reseau retire de la priorite.
8. Windows termine ses operations natives puis ouvre le compte de preparation Administrateur. L installation des logiciels et la preparation continuent en arriere-plan. La fenetre IQ Atelier peut etre reduite pour travailler.
9. Consulter le resultat final. Un avertissement signifie qu un point reste a verifier : logiciel en echec, mise a jour reportee ou redemarrage requis. Le suivi ne prouve pas qu un test manuel a ete effectue.

Le compte de preparation utilise le mode automatique deja configure dans l atelier. Avant remise au client, configurer le compte final et sa securite selon votre procedure. L ouverture automatique est desactivee a la fin de la preparation.

## Utiliser le site

Ouvrir `https://192.168.99.250`. En mode interne, l acces administrateur est automatique sur le reseau de confiance de l atelier.

- **Vue d ensemble** : progression de l image, etapes Windows, erreurs et avertissements. Cliquer sur le poste pour son journal.
- **Parc machines** : noms, MAC et rapports disponibles. Cliquer un nom pour ouvrir la fiche ordinateur.
- **Profils Windows** : images enregistrees, editions/index, logiciels et personnalisation. Pour ajouter une image, copier le WIM dans `<data_dir>\artifacts` sur le serveur puis Enregistrer un fichier. Le SHA-256 est calcule a cet enregistrement.

Dans Activite de deploiement, **Rapport PDF** telecharge le rapport du poste. **Dossier inventaire** affiche le chemin serveur et permet de telecharger XML et CSV. Les fichiers sont classes sous `<data_dir>\inventaires\NOM-DU-PC\ID-DEPLOIEMENT` sur .250. Le navigateur ne peut pas ouvrir de lui-meme l Explorateur d un autre ordinateur : copier le chemin dans l Explorateur du serveur, ou telecharger les fichiers depuis le site.

**Fiche ordinateur** rassemble historique, inventaire, PDF, resultats de tests, garantie connue et observations du technicien. Les observations sont enregistrees sur le serveur. Les nouveaux deploiements affichent les durees mesurees pour l image, WinGet, les outils constructeur, Windows Update et l inventaire. Les anciennes installations restent sans mesures. L utilisation manuelle de HP Image Assistant pour les pilotes n est pas chronometree. Apres un test ou une verification de garantie, regenerer le rapport depuis le poste pour actualiser la fiche.

## Outils sur le poste Windows

Ouvrir `C:\IQ_`. Les fichiers sont classes par categorie :

| Dossier | Usage |
| --- | --- |
| Diagnostics | Double-cliquer Test-Materiel.cmd : tester les canaux sonores, autoriser la webcam puis appuyer sur les touches. Confirmer et enregistrer le resultat. Test-Batterie.cmd genere le rapport batterie. |
| Licence | Verifier-Licence.cmd actualise l etat d activation Windows sans changer la licence. |
| Rapports | Rapport-Deploiement.pdf et Generer-Rapport.cmd pour le regenerer et retenter son envoi. |
| Inventaire | Export-Inventaire.cmd actualise XML/CSV et les transmet au serveur. |
| Garantie | Verifier-Garantie.cmd ouvre le portail officiel HP, Lenovo ou Dell. Saisir les dates confirmees : aucune date n est inventee depuis le SN. |
| Personnalisation | Fond d ecran selectionne. |

L outil de tests utilise le navigateur local : images webcam et son ne sont pas envoyes a Internet. Les resultats sont valides par l operateur. Les inventaires ne contiennent pas de cle produit complete ni de cle BitLocker. Sur un HP dont HP Image Assistant a ete reference, son executable s ouvre automatiquement a la fin pour les pilotes ; une mise a jour BIOS n est pas lancee automatiquement.

## Mises a jour et lenteur

La recherche Windows Update s arrete apres environ 90 secondes si elle ne repond pas. Une recherche terminee sans resultat affiche Aucune mise a jour necessaire trouvee et passe a la suite. Une recherche interrompue affiche Non verifie / reporte et laisse Windows Update disponible dans Parametres. Les mises a jour effectivement trouvees peuvent prendre du temps a telecharger et installer, en arriere-plan. Un redemarrage requis est annonce, sans couper votre session.

Internet est necessaire pour WinGet, les mises a jour et les portails de garantie. L installation d une application peut etre lente selon sa taille et son editeur ; consulter le nom de l etape et le journal, sans relancer simultanement le meme installateur.

## En cas de probleme

- PXE absent : verifier UEFI, Ethernet, pilotes WinPE et qu un seul serveur PXE repond.
- Mauvaise edition : choisir un autre profil correspondant a la licence, ou faire synchroniser les profils depuis le WIM par l administrateur.
- Echec avant partitionnement : lire le journal dans WinPE et dans l activite du site. Le disque ne doit pas etre efface tant que les controles ne sont pas passes.
- Logiciel en echec : consulter `C:\ProgramData\AtelierPXE\software-logs` et le PDF. Le reste de la preparation peut continuer.
- Rapport absent sur le site : le PDF local et le cache d inventaire restent conserves. Retablir le reseau puis lancer Rapports\Generer-Rapport.cmd.

Journaux du poste : `C:\ProgramData\AtelierPXE\first-logon.log`, `maintenance.log`, `reporting.log`, `progress.json`. Sur le serveur : `<data_dir>\logs\console.log` et `<data_dir>\cleanup` pour le nettoyage.

## Demarrer ou arreter le PXE

Sur le serveur qui heberge le WDS concerne, ouvrir Windows PowerShell administrateur. Ne pas activer en meme temps l ancien MDT et le nouveau PXE sur le meme reseau.

```powershell
# Arreter les reponses PXE
wdsutil /Set-Server /AnswerClients:None
Stop-Service WDSServer

# Demarrer les reponses PXE
Start-Service WDSServer
wdsutil /Set-Server /AnswerClients:All
```

Ces commandes ne desinstallent pas les images ou la console. Un poste deja en train d appliquer son image doit terminer avant une operation de maintenance du serveur.
