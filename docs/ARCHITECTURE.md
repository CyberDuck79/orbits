# lp3seq : documentation technique

Séquenceur euclidien à 7 pistes pour norns, piloté par un Novation Launchpad Mini MK3 via le mod `lp3`. Les sons passent par `nb` (une voix par piste).

Ce document explique **comment le script est construit, pourquoi, et où toucher pour modifier quelque chose**. Pour l'usage, voir la documentation utilisateur.

## 1. Vue d'ensemble

```
        Launchpad                                   norns (encodeurs, touches, écran)
            │ pads                                          │
      lp3 (mod) ──► input.on_key                  controls.enc / controls.key
                        │                                   │
                        ▼                                   ▼
                  ┌───────────────  state (S)  ───────────────┐
                  │  tracks[1..7], page, playing, sélection…  │
                  └───────────────────────────────────────────┘
                     ▲            ▲             │            │
          engine (horloges)   modulation    leds.redraw_grid   display.redraw
          joue les notes      (faders+random)  → Launchpad      → écran OLED
                     │
                     ▼
                nb players  ──► voix (une par piste)
```

Trois idées structurent tout le script :

1. **Un seul état partagé** (`lib/state.lua`). Les pads, les encodeurs, le moteur, l'écran et le Launchpad lisent et écrivent la même table `S`. Il n'y a pas de messages entre modules.
2. **Le moteur est autonome.** Chaque piste tourne dans sa propre coroutine d'horloge, à sa propre division. C'est ce qui donne polymétrie et polyrythmie sans code spécial.
3. **L'interface se redessine à partir de l'état.** Aucun module ne retient « ce qui est affiché » : `leds.redraw_grid()` et `display.redraw()` repartent de zéro à chaque appel.

## 2. Arborescence

```
lp3seq.lua            point d'entrée : câblage, init(), cleanup()
lib/
  colors.lua          palette RGB, brighten / scale_color
  consts.lua          constantes et tables de données (divisions, gammes, grooves…)
  state.lua           l'état partagé S + création des 7 pistes
  theory.lua          musique pure : gammes, transposition, arpège, phrase, groove
  steps.lua           modèle des pas : Euclide + pas manuels, accents, probabilité, micro-timing
  modulation.lua      faders de la page User + modulation aléatoire
  patterns.lua        snapshots de patterns, bascule, duplication, sauvegarde pset
  engine.lua          horloges, déclenchement des notes, répétitions, arp, chaîne song
  leds.lua            dessin du Launchpad (une fonction par page)
  pages.lua           sous-pages d'écran et pages temporaires (contrat E2/K2/E3/K3)
  display.lua         dessin de l'écran OLED
  controls.lua        gestionnaires des encodeurs et touches norns
  input.lua           gestionnaires des pads (un par page) et routage
  euclid.lua          algorithme de Bjorklund (fichier tiers, inchangé)
  nb/                 bibliothèque nb (tiers, inchangée)
tools/                déploiement et tests (voir §8)
docs/                 cette documentation
```

## 3. Couches et dépendances

Les `require` forment un graphe **sans cycle**. Chaque module ne dépend que de ceux d'en dessous :

| Couche | Modules | Dépend de |
|---|---|---|
| Données | `colors`, `consts` | rien |
| État | `state` | `consts` |
| Logique pure | `theory`, `steps`, `modulation` | données, `state` |
| Persistance | `patterns` | `consts`, `state` |
| Moteur | `engine` | logique, `patterns` |
| Interface | `leds`, `pages`, `display` | logique, `state` |
| Entrées | `controls`, `input` | `pages`, `engine`, `patterns`… |

Deux appels « vers le haut » seraient pourtant nécessaires : un module bas qui veut redessiner le Launchpad ou l'écran (par exemple `engine` après un pas). Pour éviter un cycle, `state` expose deux **hooks** :

```lua
S.redraw_grid()    -- rempli par leds.lua au chargement
S.redraw_screen()  -- rempli par display.lua au chargement
```

Au départ ce sont des fonctions vides. N'importe quel module peut les appeler sans connaître `leds` ni `display`.

## 4. L'état (`lib/state.lua`)

`S` contient :

- **Globaux de session** : `pad` (le Launchpad), `selected_track`, `page` (`drums | keys | user | session`), `current_subpage[page]`, `playing`.
- **Interaction** : `shift_held`, `selected_step`, `last_slider`, `active_temp_page`, `copy_mode_*`, `chain_edit_pos`, et les `*_pending` / `*_metro` des appuis longs.
- **Horloge visuelle** : `pulse_phase` (clignotement 250 ms), `logo_on`, `groove_pos`.
- **`tracks[1..7]`** : tout ce qui définit une piste. Chaque champ est commenté dans `S.init_tracks()`.

Conventions :
- Les scalaires modifiables s'écrivent `S.x`, jamais en copie locale (une copie locale se périme).
- `tracks` et `current_subpage` sont aussi exposés en local, car ils ne sont jamais réassignés.
- `S.play_epoch` est incrémenté à chaque start/stop. Les coroutines de répétition et d'arp le copient au départ et s'arrêtent si il a changé (c'est ce qui coupe les répétitions en cours quand on stoppe).

## 5. Le moteur (`lib/engine.lua`)

`start_sequencer()` lance, une fois pour toutes dans `init()`, 9 coroutines `clock.run` :

| Coroutine | Cadence | Rôle |
|---|---|---|
| `start_track_sequencer(t)` ×7 | `tracks[t].division` | avance la piste, tire les pas, applique la modulation |
| `start_logo_beat` | noire | fait clignoter le logo |
| `start_groove_clock` | double-croche | avance `groove_pos`, exécute les bascules de pattern et la chaîne song |

Toutes testent `S.playing`. Stop ne tue pas les coroutines, il les rend inertes.

**Un pas** (`start_track_sequencer`) : `random_tick(t)` met d'abord à jour les paramètres modulés, puis, si la piste n'est pas en mute, on prend la position, on teste `step_active` et la probabilité, on applique le micro-timing (décalage via une coroutine), puis `trigger_track`.

**`trigger_track`** calcule la vélocité (accent, courbe de groove), puis :
- arp activé → `trigger_arp_burst` (la rafale parcourt la séquence d'arpège) ;
- sinon → note_on de l'accord (phrase appliquée), note_off après 1/8 de temps, puis `trigger_repeats`.

Les **répétitions** réutilisent `repeats`, `repeat_time`, `ramp` (pente de vélocité) et `pace` (accélération). L'arp réutilise les mêmes réglages : `repeats` y fixe le nombre de notes de la rafale.

La **bascule de pattern** est volontairement faite dans `start_groove_clock` : une horloge unique en double-croche garantit que « mesure suivante » désigne le même instant pour toutes les pistes, quelle que soit leur division.

## 6. Modèles de données

### Pas (`steps.lua`)
Un pas est actif s'il tombe sur une impulsion Euclide (`euclid.lua`, après rotation) **ou** s'il a été ajouté à la main (`trk.manual[step]`). Les accents, probabilités et micro-timings des impulsions générées sont indexés par **numéro d'impulsion** (`pulse_accents[n]`), pas par position : ils suivent leur impulsion quand on change longueur, densité ou rotation. Les pas manuels portent leurs propres valeurs.

### Modulation (`modulation.lua`)
La page User expose 8 faders (`USER_SLIDERS`) : chacun décrit sa plage, comment lire/écrire la valeur d'une piste, sa couleur. Une modulation vit dans `trk.random_states[id]` :

```
{enabled, amount, rate_index, seq[16], pos, step_counter, base, last}
```

À chaque pas : `valeur = base + seq[pos] × (amount/127) × (hi−lo)/2`, bornée (ou bouclée pour la rotation). `seq` est une suite aléatoire de 16 valeurs, avancée tous les `RATE_STEPS[rate_index]` pas. `last` mémorise la dernière valeur écrite : si elle diffère de la valeur actuelle, quelqu'un a modifié le paramètre à la main, et `base` suit. Désactiver restitue `base`. Plusieurs modulations tournent en parallèle ; seule celle du fader sélectionné est éditable à l'écran.

### Patterns (`patterns.lua`)
Un pattern est un **snapshot** des champs listés dans `PATTERN_FIELDS` (rythme, notes, vélocités, répétitions, groove, gamme, arp, phrase, modulations). Ni la voix ni le mute n'en font partie. Il n'y a pas d'action « sauvegarder » : changer de pattern recapture d'abord l'actif dans son slot. 32 slots par piste (`trk.patterns`), une chaîne song de 16 positions (`trk.song_chain`).

### Sauvegarde
Les patterns ne sont pas des paramètres norns plats. `install_persistence()` branche `params.action_write` / `action_read` pour écrire un fichier annexe `<pset>.lp3seqdata` à côté du `.pset` (même technique que n.kria). Tempo et voix passent par le mécanisme pset normal.

## 7. Interface

### Launchpad (`leds.lua`, `input.lua`)
La grille 8×8 change de sens selon `S.page`. Chaque page a **un dessinateur** (`draw_*_page` dans `leds.lua`) et **un gestionnaire** (`handle_*_key` dans `input.lua`) : ils sont les deux faces d'une même page et doivent rester cohérents. La colonne droite (pistes/scènes), les flèches et la rangée du haut (changement de page) sont communes.

`on_key(x, y, z)` route : bouton Stop/Solo/Mute (tap = play, maintenu = shift + page tempo), pistes, flèches, boutons de page, sinon le gestionnaire de la page courante.

`redraw_grid()` redessine tout dans le tampon du mod `lp3`, puis `refresh()` (incrémental : seules les LED modifiées sont envoyées).

Les appuis longs (pas, slots, shift+piste) utilisent deux métros à un coup, `hold_metro` et `mute_hold_metro`, créés dans `create_timers()`.

### Écran et encodeurs (`pages.lua`, `display.lua`, `controls.lua`)
L'écran ne répète pas ce que la grille montre déjà. Chaque page grille a des **sous-pages** (`subpages[page]`), parcourues avec E1. Une sous-page décrit jusqu'à quatre **slots** :

```lua
{name = "velocity",
 e2 = {available = fn?, label = fn, value = fn, delta = fn(d)},
 k2 = {available = fn?, label = fn, state = fn, action = fn},
 e3 = …, k3 = …}
```

`controls.lua` ne connaît aucune page : il appelle le slot de la sous-page courante (`current_subpage_def()`) si `slot_ready` (présent et `available()` vrai). `display.lua` dessine les mêmes slots, ce qui garantit que ce qu'on voit est ce qu'on pilote. Les **pages temporaires** (`temp_pages`, aujourd'hui seulement « tempo ») suivent le même contrat et remplacent la sous-page tant que leur bouton est maintenu.

Garde de redessin : `display.redraw()` ne fait rien quand un menu système norns est ouvert, sinon les horloges écrasent l'écran du menu.

## 8. Outils et tests (`tools/`)

- `deploy.sh` : copie le script vers le norns (`ssh norns`).
- `check.sh <réf-git> [graine]` : vérifie qu'un refactor ne change rien. Il rejoue une longue session scriptée (pads, encodeurs, touches, horloge virtuelle, API norns simulées) sur l'ancienne version et sur le dossier courant, puis compare **octet par octet** les LED, appels d'écran et notes émises.
- `harness.lua` : le pilote de test (aléatoire déterministe par graine, `COVER=1` pour la couverture de lignes).

Le banc ne couvre que des E/S simulées : il prouve l'absence de régression, pas le bon fonctionnement matériel. Il ne simule pas non plus le menu système. Un changement **voulu** de comportement fait diverger le test : c'est normal, il faut alors comparer à la main.

## 9. Pièges connus

- **`include` vs `require`.** `include` n'a pas de cache ; `require` si. `lp3seq.lua` purge donc les entrées `package.loaded` commençant par `lp3seq/` au démarrage, sinon un rechargement du script réutiliserait les modules périmés.
- **Version de Lua.** norns (matron) tourne en Lua 5.3, le shell a 5.1/LuaJIT. Éviter ce qui diffère (opérateurs entiers, `//`) ou le vérifier sur l'appareil.
- **Globales accidentelles.** Seuls `init`, `cleanup`, `enc`, `key`, `redraw` doivent être globaux. Contrôle : `luac -l` (Lua 5.1 du shell) sur chaque fichier : seuls les accès `GETGLOBAL` vers la bibliothèque standard et les API norns sont normaux.
- **Dessin sur l'écran.** `screen.rect` est sûr ; `screen.circle` suivi de `stroke` laisse des traits parasites (point courant de Cairo). Les pastilles rondes (`draw_round_dot`) sont donc faites de trois `rect` remplis, sans arc.
- **Mod `lp3`.** `connect()` renvoie `false` sans Launchpad mais attend la connexion ; `pad.status` est optionnel et sert à l'indicateur « Launchpad débranché » ; le module est en cache au démarrage de matron (redémarrer matron après modification du mod).
- **`clock.lua:62 bad argument #1 to 'resume'`** dans le journal au changement de script : course interne de norns, déjà présente avant le découpage, sans effet.
- **Redessiner depuis une horloge.** Appeler `S.redraw_grid()` depuis une coroutine est normal, mais chaque appel déclenche aussi `redraw_screen`. C'est voulu (simple) et assez léger ici.

## 10. Où modifier quoi

| Je veux… | Je touche… |
|---|---|
| Ajouter une division, une gamme, un groove, un style d'arp | `consts.lua` (et le dessin/gestionnaire si une grille d'affichage change) |
| Changer une couleur | `colors.lua` (couleurs de paramètres : `modulation.lua`, `USER_SLIDERS`) |
| Ajouter un paramètre de piste | `state.lua` (`init_tracks`) ; `patterns.lua` (`PATTERN_FIELDS` **et** `fresh_pattern_snapshot`) s'il fait partie d'un pattern ; son usage dans `engine.lua` |
| Changer comment une note est jouée (vélocité, durée, répétition) | `engine.lua` (`trigger_track`, `trigger_repeats`, `trigger_arp_burst`) |
| Changer l'arpège ou la phrase | `theory.lua` (`arp_sequence`, `apply_phrase`) |
| Changer la logique des pas (accent, probabilité, micro-timing) | `steps.lua` |
| Ajouter un fader modulable | `modulation.lua` : une entrée dans `USER_SLIDERS` (la page User et l'écran la prennent en charge) |
| Changer le comportement d'une page du Launchpad | `leds.lua` (`draw_*_page`) **et** `input.lua` (`handle_*_key`) |
| Ajouter ou modifier ce que font E2/K2/E3/K3 | `pages.lua` : la sous-page concernée (`controls.lua` ne change pas) |
| Changer l'aspect de l'écran (icônes, mise en page) | `display.lua` |
| Changer les boutons de page, flèches, play/shift, mute | `input.lua` (`on_key`, `handle_arrow`) |
| Changer la bascule de pattern, la chaîne song | `engine.lua` (`start_groove_clock`) et `patterns.lua` |
| Changer ce qui est sauvegardé | `patterns.lua` (`install_persistence`) |
| Changer l'init / le nettoyage | `lp3seq.lua` |

Après toute modification : `sh tools/check.sh <réf>` (pour un refactor), puis `sh tools/deploy.sh` et un essai sur le matériel.
