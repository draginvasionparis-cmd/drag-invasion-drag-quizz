# Drag Invasion — Quiz Royale

Application statique HTML/CSS/JavaScript, connectée au projet Supabase existant. Aucun secret serveur dans les fichiers : seule la clé publique est utilisée.

## Fonctionnement

1. Préparer les questions dans le studio. Le brouillon reste sur cet appareil ; l'export JSON inclut les médias.
2. Dans l'écran animateur, se connecter avec le compte de **Supabase Authentication** (distinct du compte du tableau de bord Supabase).
3. Créer une partie. Partager le code à six caractères, le lien ou le QR.
4. Les joueurs entrent un pseudo unique pendant la salle d'attente. Ils peuvent reprendre leur session après actualisation sur le même navigateur.
5. Lancer la partie, révéler chaque réponse puis passer à la suivante. La dernière question termine la partie et conserve les résultats.

100 points par bonne réponse ; une réponse par joueur et par question. Le serveur contrôle les jetons joueurs, le temps imparti et l'identité de l'animateur. Les doubles envois sont idempotents. La synchronisation interroge le serveur toutes les 1,2 secondes et reprend après une coupure. Ce mécanisme n'utilise pas les WebSockets Supabase Realtime.

## Installation et état

La migration `supabase-migration.sql` a été appliquée au projet existant le 22 octobre 2026. Elle ajoute `question_started_at` et `revealed`, corrige les positions des questions et ajoute les fonctions `royale_state`, `royale_answer` et `royale_control`. Les tables existantes et leurs protections RLS sont conservées.

Les fonctions `save_quiz`, `create_game`, `join_game` et `start_game` déjà créées sont réutilisées. Aucune Edge Function n'était déployée lors de l'audit ; le navigateur utilise directement les RPC PostgreSQL avec les permissions appropriées.

Servir ce dossier avec un serveur HTTP statique pour le développement. Pour GitHub Pages, conserver `index.html`, `app.js` et `qrcode.js` avec la même structure. Le QR utilise l'URL courante : une prévisualisation doit être accessible sur Internet pour être ouverte par un téléphone.

Le compte animateur doit déjà exister dans Supabase Authentication. L'application n'inscrit aucun nouveau compte et ne modifie aucun mot de passe.

## Vérification

```sh
npm ci
npm test
npm run check
```

Les tests d'interface utilisent un DOM simulé avec deux sessions joueurs indépendantes et un transport simulé. Ils vérifient création, attente, réponse, double clic, révélation, passage de question, classement final, reprise, QR, validation d'import, coupure réseau et minuterie.

`database-tests.sql` a également été exécuté dans le **vrai projet Supabase** : partie à deux joueurs, scores, faux jeton, mauvaise question, double réponse, pseudo en double, contrôle animateur, commande périmée, délai dépassé, temps illimité, révélation et fin. Le script annule toutes ses données de test dans une transaction.

Limites de validation : l'exécution visuelle de l'interface dans un navigateur et une partie sur plusieurs téléphones restent à vérifier sur une prévisualisation HTTP. Aucune modification n'a été envoyée sur GitHub et aucune nouvelle version n'a été publiée.

La bibliothèque QR `qrcode-generator` 2.0.4 de Kazuhiko Arase est incluse sous licence MIT.
