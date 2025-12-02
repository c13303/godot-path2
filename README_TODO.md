Objectif : introduire dans un système de steering une force smash déclenchée par une explosion.

Contraintes :
– smash est une impulsion appliquée une seule frame.
– smash_force est stockée par agent et diminue automatiquement par friction.
– Aucun timer ; extinction lorsque la magnitude devient faible.
– Hiérarchie : wall_repulsion > smash > neighbor_avoidance > flow.
– Lorsque smash_force est significative : désactiver l’influence du flow.
– Le mouvement final combine toutes les forces avec pondérations cohérentes.
– La propagation doit diffuser partiellement smash_force aux voisins immédiats selon un facteur défini.
– La propagation ne doit jamais amplifier au-delà de la force initiale locale.
– Le système doit rester compatible avec wall correction existante.

Implémentation attendue :
– Ajouter smash_force au sein de AgentData.
– Ajouter friction_factor, smash_threshold, propagation_factor dans la configuration.
– Ajouter une fonction apply_explosion(pos, radius, intensity) qui initialise smash_force.
– Modifier update_all pour :
  1. Atténuer smash_force par friction.
  2. Propager une portion aux voisins.
  3. Intégrer smash_force dans le calcul des forces avant flow.
  4. Ignorer flow quand smash_force dépasse smash_threshold.
  5. Reprendre le comportement normal lorsque smash_force devient négligeable.
– Garantir que ultimate_wall_correction reste prioritaire.
