# Comprendre les états Atelier PXE

## Déploiement du poste

| Affichage | Ce qui est confirmé |
| --- | --- |
| Image appliquée, préparation Windows attendue | WinPE a préparé le disque et le démarrage. La préparation Windows n’a pas encore envoyé de progression. |
| Préparation Windows en cours | Un signal Windows a été reçu. Le dernier contact et le temps écoulé permettent de situer l’avancement. |
| Redémarrage Windows attendu | Un redémarrage a été demandé. Il ne devient terminé qu’après confirmation d’un nouveau démarrage. |
| Préparation terminée, bilan attendu | Le client annonce la fin, mais le serveur attend encore son rapport. |
| Préparation réussie | Un bilan Windows réussi a été reçu. Cela décrit les contrôles automatiques de la préparation. |
| Préparation à vérifier | Le bilan contient un résultat incomplet ou un avertissement. Le message précise le point concerné. |
| Résultat non transmis | L’agent n’a pas transmis la fin de cette étape. Une autre étape réussie ne remplace pas cette preuve. |

Le bouton **Suivre les étapes** ouvre les six étapes : Image Windows, HPIA, Logiciels, Dossier IQ, Redémarrage et Bilan. Le compteur mesure le temps écoulé depuis la première réception du début par le serveur. Il peut inclure des attentes ou des redémarrages. Un ancien contact ne prouve pas à lui seul un blocage. Le pourcentage Windows est distinct de celui de l’application de l’image.

Les nouveaux signaux nécessitent le WinPE IQ-6.2. Les anciens déploiements restent consultables ; leurs étapes manquantes ne sont pas reconstruites à partir du seul pourcentage.

## Cache HP et source du poste

| Affichage | Signification |
| --- | --- |
| Cache disponible | Une copie publiée depuis moins de 24 heures est présente avec la taille enregistrée. Le poste doit encore vérifier ses recommandations et les fichiers téléchargés. |
| Copie conservée, à actualiser | La copie date de plus de 24 heures. Elle reste stockée, mais nécessite une actualisation pour être réutilisée automatiquement. |
| Actualisation échouée | La dernière préparation du cache serveur a échoué. Ce résultat ne dit pas que HPIA a échoué sur un poste. Une copie précédente peut subsister. |
| Téléchargement direct chez HP | Le bilan du poste déclare les serveurs HP comme source. Le poste doit disposer d’un accès Internet. |
| Cache .250, analyse HP par Internet | Les paquets proviennent du cache, tandis que l’analyse HPIA utilise Internet. |
| Aucune source déclarée | Aucun bilan reçu ne permet de confirmer la source utilisée par le poste. |

Les sources des bilans sont conservées par plateforme et version Windows. Une plateforme utilisée par plusieurs postes peut présenter plusieurs sources. La présence d’un fichier sur .250 ne confirme jamais son installation sur un PC.

## Correctifs et stockage

**Fichiers KB disponibles sur .250** signifie que les paquets sont préparés sur le serveur. Les KB et Windows Update restent manuels pendant la préparation des nouveaux postes. La veille d’une nouvelle version Windows ne télécharge pas de média et ne met aucun poste à niveau.

Les anciens états DISM concernent une image candidate : « prête à tester » et « publiée » sont deux étapes distinctes. Le stockage est présenté une seule fois, dans la vue globale, avec sa date de mesure.
