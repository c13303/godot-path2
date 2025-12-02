Objectif : ajouter une force smash dans le système de steering C++ (Godot 4.5, GDExtension), déclenchée par une explosion, amortie naturellement, propagée aux voisins, et intégrée proprement dans la hiérarchie existante.

--------------------------------------------------------------------
Contexte existant
--------------------------------------------------------------------
– update_all applique actuellement : wall_repulsion > neighbor_separation > flow > lerp.
– SpatialGrid fournit les voisins (query_neighbors).
– FlowField donne la direction globale.
– AgentData contient position, velocity, flow, active, etc.
– GlobalConfig contient les strengths : wall_repel_strength, separation_strength, flow_weight.

--------------------------------------------------------------------
Mécanique smash
--------------------------------------------------------------------
– Impulsion appliquée une seule frame via apply_explosion.
– smash_force stockée dans AgentData.
– smash_force diminue via friction_factor.
– Extinction naturelle via smash_min_cutoff (pas de timer).
– Priorité : wall > smash > neighbors > flow.
– Le flow est ignoré si smash dépasse smash_threshold.
– Propagation : portion (A→B) = (A.smash − B.smash) * propagation_factor, sans amplification.
– Compatible avec ultimate_wall_correction.

--------------------------------------------------------------------
Ajouts requis
--------------------------------------------------------------------
AgentData :
    Vec2 smash_force = Vec2(0,0);

GlobalConfig :
    double friction_factor;        // 0.90–0.98
    double smash_threshold;        // seuil flow off (5.0–15.0)
    double propagation_factor;     // 0.05–0.20
    double smash_min_cutoff;       // extinction automatique (~0.1)
    double propagation_threshold;  // optimisation 2000 agents (~1.0)

--------------------------------------------------------------------
apply_explosion(Vec2 pos, radius, intensity)
--------------------------------------------------------------------
– Utiliser SpatialGrid.query_neighbors(pos, radius).
– Pour chaque agent A :
      diff = A.position − pos
      fallback si |diff| < epsilon
      attenuation = max(0, 1 − dist/radius)²
      A.smash_force += normalize(diff) * intensity * attenuation
– Appelé une seule frame.

--------------------------------------------------------------------
update_all — Pipeline modifié
--------------------------------------------------------------------

1. Atténuation :
    A.smash_force *= friction_factor
    si |A.smash_force| < smash_min_cutoff → smash_force = 0

2. Propagation (two-pass obligatoire) :

Pass 1 :
    pour chaque agent A :
        si |A.smash_force| < propagation_threshold : continuer
        voisins = grid->query_neighbors(A.position, separation_radius)
        pour chaque voisin B :
            si |A.smash_force| > |B.smash_force| :
                delta = (A.smash_force − B.smash_force) * propagation_factor
                buffer[B] += delta

Pass 2 :
    B.smash_force += buffer[B]
    buffer[B] = Vec2(0,0)

3. Intégration hiérarchique des forces

Option A (recommandée) : **utiliser les strengths existants**  
→ Cela garantit la cohérence du tuning général.

    total_force =
        wall_repulsion * 1.0                                  // prioritaire
        + normalize(smash_force) * smash_strength_effective   // cf. tuning
        + separation_force                                     // utilise separation_strength existant
        + flow_dir * (flow_weight si smash < smash_threshold)

smash_strength_effective = clamp(|smash_force|, 0, smash_cap)

smash_cap recommandé : 150–600 selon gameplay  
Justification : la magnitude brute de smash_force peut dépasser les forces existantes, il faut la borner.

Option B (pondérations W1–W4 explicites) :

W1 = 1.0         // murs absolus  
W2 = 0.6–0.9     // smash fort mais contrôlé  
W3 = 0.1–0.2     // separation influence faible  
W4 = 0.05–0.1    // flow très faible dans cet état  

Utiliser cette option uniquement si tu veux une hiérarchie indépendante des strengths existants.

4. Suspension du flow :
    si |A.smash_force| > smash_threshold :
        ignorer complètement flow_dir

5. Reprise automatique :
    si smash_force ≈ 0 :
        flow réactivé naturellement

--------------------------------------------------------------------
Côté Godot
--------------------------------------------------------------------
– Touche B : obtenir mouse_world_position.
– steering_system_native.apply_explosion(pos, radius, intensity)
– Afficher un cercle rouge 1s pour debug (CanvasLayer).

--------------------------------------------------------------------
Contraintes de stabilité
--------------------------------------------------------------------
– Ne jamais réactiver agent.active si agent.arrived.
– ultimate_wall_correction garde priorité.
– smash compatible avec lerp_general.
– Propagation two-pass obligatoire pour éviter les asymétries.
– smash_force doit être bornée (smash_cap) pour éviter des accélérations extrêmes.

--------------------------------------------------------------------
Tuning recommandé (point de départ stable)
--------------------------------------------------------------------
friction_factor         = 0.92
propagation_factor      = 0.08      // réduit pour 2000 agents
propagation_threshold   = 1.0       // skip propagation si smash < 1.0
smash_threshold         = 10.0
smash_min_cutoff        = 0.1
smash_cap               = 300.0
intensity               = 300–500
radius                  = 64–100 px // touche 100-200 agents
flow_weight             = existant
separation_strength     = existant
wall_repel_strength     = existant

Ces valeurs doivent être adaptées selon gameplay.

--------------------------------------------------------------------
Optimisation pour 2000 agents
--------------------------------------------------------------------
– Préallouer propagation_buffer avec reserve(2048) dans constructor.
– Skip propagation si magnitude(smash_force) < propagation_threshold.
– Explosion touche ~100-200 agents max (via spatial grid).
– Propagation active sur ~200-400 agents pendant 0.5-1s.
– Coût estimé : ~3-5ms/frame (30% budget à 60 FPS) → acceptable.

--------------------------------------------------------------------
Résultat attendu
--------------------------------------------------------------------
– Agents proches sont projetés immédiatement.  
– Onde secondaire via propagation maîtrisée.  
– Amortissement naturel.  
– Retour automatique au flow.  
– Aucun franchissement de mur.  
