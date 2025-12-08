# Godot Flowfield Pathfinding System

## Vue d'ensemble

Système de navigation et de pathfinding pour foules utilisant la technique des flowfields, implémenté avec une extension C++ GDExtension pour Godot 4.5. Le système permet la gestion efficace de dizaines d'agents avec pathfinding en temps réel et steering behaviors.

### Technologies

- **Godot 4.5** - Moteur de jeu
- **C++ GDExtension** - Extension native pour performance
- **Flowfield Algorithm** - Navigation scalable pour foules
- **Spatial Grid** - Accélération spatiale pour requêtes de voisinage
- **Force-based Steering** - Comportements de mouvement basés sur des forces

---

## Architecture du projet

### Structure des répertoires

```
projet_godot/
├── extensions/flowfield/          # Extension C++ (cœur du système)
│   ├── core/                      # Types de base et configuration
│   ├── flow/                      # Système de flowfield
│   ├── steering/                  # Système de steering
│   ├── grid/                      # Grille spatiale
│   ├── agent_manager/             # Gestion de groupes
│   └── native/                    # Wrappers Godot natifs
├── character/                      # Scènes et scripts des agents
├── controls/                       # Gestion des entrées
├── pathfinder/                     # Coordinateur flowfield
├── global/                         # Utilitaires et autoload
├── UI_elements/                    # Composants UI
├── png/                            # Assets graphiques
└── TILEMAP_EXPERIMENT2.tscn        # Scène principale
```

### Configuration du projet

**Fichier:** `project.godot`

- **Scène principale:** TILEMAP_EXPERIMENT2.tscn
- **Autoload:** Utils (global/utils.gd)
- **Rendu:** GL Compatibility (compatible mobile)
- **Résolution:** 1600×900 avec mise à l'échelle entière
- **Godot Version:** 4.5+

---

## Extension C++ - Architecture détaillée

### 1. Core Components (`extensions/flowfield/core/`)

#### types.h - Types fondamentaux
```cpp
struct Vec2 {
    double x, y;
    // Opérations: add, sub, mul, normalize, dot, distance
};

struct Vec2i {
    int x, y;
};
```

#### nav_config.h - Constantes statiques
```cpp
MAX_FLOWFIELDS = 64        // Nombre max de flowfields simultanés
MAX_GROUPS = 64            // Nombre max de groupes
FLOW_WIDTH = 256           // Largeur en cellules
FLOW_HEIGHT = 256          // Hauteur en cellules
FLOW_TILE_SIZE = 16.0      // Taille d'une cellule en pixels
```

#### global_config.h - Configuration dynamique
```cpp
struct GlobalConfig {
    // Forces de navigation
    double flow_weight = 1.0;              // Influence du flowfield
    double center_pull = 1.0;              // Attraction vers le centre du goal

    // Géométrie
    double tile_size = 16.0;               // Taille de cellule (px)

    // Évitement de murs
    double wall_avoid_radius = 19.2;       // Rayon de détection (px)
    double wall_repel_strength = 8.4;      // Force de répulsion

    // Séparation entre agents
    double separation_radius = 18.0;       // Rayon de séparation (px)
    double separation_strength = 400.0;    // Force de séparation
    int max_neighbors = 16;                // Limite de voisins pour requêtes

    // Arrivée dynamique (fonction du nombre d'agents du groupe)
    double target_T1_param_tile_ratio = 0.5;        // Rayon T1 = tile_size * ratio * sqrt(nb_agents)
    double target_T2_param_margin = 32.0;           // Marge ajoutée autour de T1 (par défaut 2 * tile_size)
    double target_T2_param_minimal_speed = 4.0;     // Vitesse mini en T2 (par défaut max(1, 0.25 * tile_size))

    // Lissage
    double lerp_general = 0.02;            // Facteur de lissage du mouvement
};
```

---

### 2. Flowfield System (`extensions/flowfield/flow/`)

#### FlowField - Champ de navigation

**Responsabilité:** Calcule et stocke un champ de directions vectorielles pour guider les agents vers un objectif.

**Données clés:**
```cpp
class FlowField {
    Vec2 dirs[FLOW_HEIGHT][FLOW_WIDTH];    // Directions par cellule
    Vec2i goal_cell;                        // Cellule objectif
    double tile;                            // Taille de cellule
    int w, h;                               // Dimensions
    int refcount;                           // Compteur de références
};
```

**Méthodes principales:**
- `compute()` - Calcul du flowfield par Dijkstra
- `compute_flow_dir(Vec2 world_pos)` - Échantillonne la direction à une position
- `world_to_cell()` / `cell_to_world()` - Conversions de coordonnées
- `is_cell_navigable()` - Vérifie si une cellule est valide
- `find_nearest_navigable()` - Recherche en spirale de la cellule valide la plus proche

**Algorithme de calcul:**
1. Extraction des couches floor/wall depuis tilemap
2. Construction des sets de cellules navigables vs obstacles
3. Calcul du champ de coûts (Dijkstra depuis l'objectif)
4. Calcul des directions (chaque cellule pointe vers le voisin de coût minimal)
5. Ajustement des tangentes aux murs pour un steering naturel
6. Calcul du distance field depuis les murs (BFS)

---

#### FlowFieldManager - Gestionnaire de flowfields

**Responsabilité:** Gère jusqu'à 64 flowfields simultanés avec reference counting.

**Méthodes:**
- `register_existing(FlowField*)` - Enregistre un flowfield existant
- `create_field(goal)` - Crée un nouveau flowfield
- `get(FlowFieldID)` - Récupère un flowfield par ID
- `remove(FlowFieldID)` - Supprime un flowfield (avec refcount)

---

### 3. Steering System (`extensions/flowfield/steering/`)

#### SteeringSystem - Contrôleur de mouvement

**Responsabilité:** Met à jour tous les agents chaque frame en appliquant les forces de steering.

**Structure d'agent:**
```cpp
struct AgentData {
    int id;                    // Identifiant unique
    Vec2 position;            // Position monde
    Vec2 velocity;            // Vélocité actuelle
    double max_speed;         // Vitesse maximale (60-100 typique)
    bool active;              // Répond au flowfield si true
    FlowField *flow;          // Flowfield assigné
    bool has_arrived;         // A atteint l'objectif
    bool is_first;            // Premier agent arrivé (tracking)
    GroupID group;            // Groupe d'appartenance
};
```

**Méthodes principales:**
- `register_agent(pos, max_speed, group)` - Crée un agent, retourne ID
- `update_all(delta)` - Boucle principale de mise à jour
- `force_voisine(agent)` - Calcule la force de séparation avec les voisins
- `wall_repulsion_force(agent)` - Répulsion depuis les murs
- `ultimate_wall_correction(agent)` - Correction d'urgence anti-mur

**Pipeline de mise à jour (update_all):**
```
Pour chaque agent:
    1. Calculer wall_repulsion_force
       - Requête des cellules de mur proches
       - Application d'une répulsion exponentielle

    2. Calculer force_voisine (séparation)
       - Requête spatial grid pour voisins
       - Force proportionnelle à la proximité

    3. Si agent inactif (pas de flowfield):
       - Déplacement avec wall + séparation uniquement
       - Utilise 25% de max_speed

    4. Si agent actif (a un flowfield):
       - Échantillonne direction du flowfield
       - Combine avec répulsion/séparation
       - Vérifie collision mur et applique correction
       - Lisse la vélocité avec lerp

    5. Mise à jour position: position += velocity * delta

    6. Vérification arrivée:
       - Si dans zone d'arrivée, marquer arrived
       - Track "first arrived" pour le groupe
```

**Hiérarchie des forces:**
```
Priorité décroissante:
1. Wall repulsion (highest priority)
2. Neighbor separation
3. Flowfield direction (si active)
4. Smooth movement (lerp)
```

---

### 4. Spatial Grid (`extensions/flowfield/grid/`)

#### SpatialGrid - Accélération spatiale

**Responsabilité:** Structure d'accélération par hash pour requêtes de voisinage efficaces.

**Configuration:**
- Taille de cellule: 32 pixels (2 tiles)
- Hash: `long long` depuis coordonnées (x,y) de cellule
- Complexité: O(1) insertion/suppression, O(k) requête (k = nb voisins)

**Méthodes:**
- `insert(id, pos)` - Ajoute un agent
- `update(id, old_pos, new_pos)` - Déplace un agent
- `query_neighbors(pos, radius)` - Retourne les agents dans le rayon
- `remove(id)` - Retire un agent

---

### 5. Agent Manager (`extensions/flowfield/agent_manager/`)

#### AgentManager - Gestion de groupes

**Responsabilité:** Organise les agents en groupes/squads, gère l'assignation de flowfields par groupe.

**Structure:**
```cpp
struct AgentEntry {
    int id;              // ID de l'agent
    GroupID group;       // Groupe assigné
    Vec2 position;       // Position de l'agent
};
```

**Méthodes:**
- `create_group()` - Crée un groupe, retourne GroupID
- `add_agent_to_group(agent_id, group_id)` - Assigne un agent à un groupe
- `get_group_flow(group_id)` - Récupère le flowfield du groupe
- `set_group_flow(group_id, flow)` - Assigne un flowfield au groupe
- `dissolve_group(group_id)` - Dissout un groupe

**Capacité:** Jusqu'à 64 groupes simultanés.

---

## Bindings Godot Natifs

### Classes exposées à GDScript

#### 1. FlowFieldNative (Node2D)
Wrapper Godot pour FlowField.

**Propriétés:**
- `floor_layer` - Référence à la couche de sol (TileMapLayer)
- `wall_layer` - Référence à la couche de murs (TileMapLayer)

**Méthodes:**
- `rebuild_async(goal_position)` - Recalcule le flowfield (thread)
- `compute_flow_dir(world_pos)` - Échantillonne direction
- `assign_flow_to_group(group_id)` - Assigne à un groupe

**Debug:** Peut dessiner les vecteurs de direction pour visualisation.

---

#### 2. SpatialGridNative (Node)
Wrapper pour SpatialGrid.

---

#### 3. SteeringSystemNative (Node2D)
Wrapper pour SteeringSystem.

**Méthodes:**
- `_process(delta)` - Appelle `update_all(delta)` sur le système C++
- Connecté à FlowFieldNative et SpatialGridNative

---

#### 4. AgentManagerNative (Node)
Wrapper pour AgentManager.

**Méthodes:**
- `create_group()` - Crée un groupe
- `spawn_agent(pos, max_speed, group)` - Crée un agent
- `assign_agent(agent_id, group_id)` - Assigne à un groupe

Maintient une table de liens entre les nodes Godot et les agents du steering system.

---

#### 5. GlobalConfigNative (Node)
Expose GlobalConfig pour tweaking en temps réel.

---

## Couche GDScript

### Scripts principaux

#### 1. character/character.gd
Script de l'agent (CharacterBody2D).

```gdscript
extends CharacterBody2D
class_name FlowAgent

@export var use_native_steering := true   # Utilise steering C++
@export var max_speed: float = 100.0
@export var max_force: float = 1200.0

var nav_id: int = -1      # Référence agent dans SteeringSystem
var arrived: bool = false
```

---

#### 2. controls/controls.gd
Gestion des entrées utilisateur.

**Contrôles:**
- **CLIC GAUCHE + DRAG:** Sélection rectangulaire d'unités
- **CLIC DROIT:** Définir objectif pour le groupe sélectionné
- **TOUCHE A:** Spawn 1 personnage
- **TOUCHE Z:** Spawn 10 personnages
- **TOUCHE E:** Spawn 50 personnages
- **MOLETTE:** Zoom caméra

**Fonctionnalités:**
- Sélection de groupe visuelle (rectangle)
- Spawn avec recherche de cellule libre
- Assignation d'objectif via clic droit
- Zoom caméra

---

#### 3. pathfinder/FlowFieldCode.gd
Coordinateur du flowfield.

**Responsabilités:**
- Initialise flowfield avec les couches tilemap
- Déclenche le calcul du flowfield au changement d'objectif

**Méthodes:**
- `_on_mouse_goal(goal_pos)` - Appelle `rebuild_async(goal_pos)`

---

#### 4. global/utils.gd
Autoload global pour setup.

---

## Scène principale

**Fichier:** TILEMAP_EXPERIMENT2.tscn (1269 lignes)

### Hiérarchie:
```
Root
├── TileMapLayer (MonTilemap)
│   ├── floor layer (cellules navigables)
│   └── wallz layer (obstacles)
├── FlowFieldNative (Calcul navigation)
│   └── FlowFieldCode.gd (Coordinateur)
├── SpatialGridNative (Accélération voisinage)
├── SteeringSystemNative (Mise à jour agents)
├── AgentManagerNative (Gestion groupes)
├── Controls (Entrées + UI)
├── CanvasLayer (UI overlay)
│   └── SelectionRect (Feedback visuel)
├── Camera2D (Contrôle vue)
└── Agents (spawn runtime)
    └── MainChar (CharacterBody2D + character.gd)
```

### Configuration Tilemap:
- TileSetAtlasSource avec tuiles 16×16
- Polygones de navigation pour chaque type de tuile
- Couches floor et wall pour pathfinding

---

## Compilation et Build

### Structure:
```
FLOWFIELD_CPP/
├── godot-cpp/              # Bindings C++ Godot (CMake/SCons)
├── godot451/               # Éditeur Godot 4.5.1
├── src/                    # Source extension (ancien?)
└── projet_godot/           # Projet Godot principal
    └── extensions/flowfield/
        ├── bin/flowfield.dll   # DLL compilée
        └── flowfield.gdextension
```

### Build Extension:
- **Sortie:** `extensions/flowfield/bin/flowfield.dll`
- **Fichier GDExtension:** `flowfield.gdextension`
- **Entry point:** `flowfield_library_init` (register_types.cpp)
- **Targets:** Windows x86_64 (debug & release)
- **Tools:** SCons (traditionnel Godot), CMake disponible

---

## Algorithme Flowfield - Détails

### Processus de calcul:

1. **Préparation des couches**
   - Extraction des cellules floor/wall depuis tilemap

2. **Construction des sets**
   - Identification cellules navigables vs obstacles

3. **Calcul des coûts**
   - Dijkstra: distance field depuis l'objectif
   - Coût = distance en cellules

4. **Calcul des directions**
   - Pour chaque cellule: pointer vers le voisin de coût minimal
   - Support diagonales (configurable)

5. **Ajustement tangentes**
   - Lissage des directions près des murs
   - Steering plus naturel autour des obstacles

6. **Distance field**
   - BFS depuis les murs
   - Utilisé pour wall avoidance

### Caractéristiques:
- Résolution: 256×256 cellules
- Interpolation bilinéaire pour directions lisses
- Reference counting pour partage multi-groupe
- Calcul asynchrone (thread)

---

## Pipeline de mouvement

### Update par frame (SteeringSystem::update_all):

```cpp
Pour chaque agent:
    // 1. WALL REPULSION (priorité max)
    wall_force = wall_repulsion_force(agent)

    // 2. SEPARATION (voisins)
    separation_force = force_voisine(agent)

    // 3. FLOW DIRECTION (si actif)
    if (agent.active && agent.flow) {
        flow_dir = agent.flow->compute_flow_dir(agent.position)
        flow_force = flow_dir * flow_weight
    }

    // 4. COMBINAISON DES FORCES
    total_force = wall_force + separation_force + flow_force

    // 5. LISSAGE
    agent.velocity = lerp(agent.velocity, total_force, lerp_factor)

    // 6. COLLISION CHECK & CORRECTION
    if (collision_detected) {
        ultimate_wall_correction(agent)
    }

    // 7. MISE À JOUR POSITION
    agent.position += agent.velocity * delta

    // 8. VÉRIFICATION ARRIVÉE (radii dynamiques)
    t1_radius = tile_size * target_T1_param_tile_ratio * sqrt(group_size)
    if (distance_to_goal <= t1_radius && speed <= stop_threshold) {
        agent.has_arrived = true
    }
```

### Pondération des forces (GlobalConfig):
- Flow influence: **1.0×**
- Separation strength: **400.0**
- Wall repel strength: **8.4**
- Direct steering radius: **40 pixels** (2.5 × tile_size)
- Max neighbors considered: **16**

---

## Performances

### Capacités:
- **Agents testés:** 50+ simultanés
- **Résolution flowfield:** 256×256 cellules = 65,536 directions
- **Fréquence mise à jour:** 60 FPS (par défaut Godot)
- **Taille cellule spatial grid:** 32 pixels (2 tuiles)
- **Limite requête voisins:** 16 agents les plus proches

### Complexités:
- **Calcul flowfield:** O(W × H × log(W × H)) Dijkstra
- **Update agent:** O(n) avec n = nombre d'agents
- **Requête voisins:** O(1) hash + O(k) avec k = voisins dans rayon

---

## État de développement actuel

### Branch: `clean_flow_field`

**Fichiers modifiés:**
- TILEMAP_EXPERIMENT2.tscn
- Nouveaux: README_TODO.md, REAME.md

### Tâche en cours: Système de force d'explosion/smash

**Objectif:** Introduire une force impulsive d'explosion qui se propage aux agents voisins.

**Contraintes:**
- `smash` est une impulsion appliquée une seule frame
- `smash_force` stockée par agent, diminue par friction
- Extinction automatique quand magnitude faible (pas de timer)
- **Hiérarchie:** `wall_repulsion > smash > neighbor_avoidance > flow`
- Quand smash significatif: désactiver flow
- Propagation partielle aux voisins sans amplification
- Compatible avec wall correction existante

**Implémentation attendue:**

1. **Ajout dans AgentData:**
   ```cpp
   Vec2 smash_force;
   ```

2. **Ajout dans GlobalConfig:**
   ```cpp
   double friction_factor;        // Atténuation par frame
   double smash_threshold;        // Seuil pour désactiver flow
   double propagation_factor;     // Portion propagée aux voisins
   ```

3. **Nouvelle fonction:**
   ```cpp
   void apply_explosion(Vec2 pos, double radius, double intensity);
   ```

4. **Modification update_all:**
   ```cpp
   // Dans update_all():
   1. Atténuer smash_force par friction
   2. Propager une portion aux voisins
   3. Intégrer smash_force avant flow
   4. Ignorer flow si magnitude(smash_force) > smash_threshold
   5. Reprendre comportement normal quand smash négligeable
   ```

5. **Garantir:** `ultimate_wall_correction` reste prioritaire

**Commits récents:**
- `5a75243` - [CLEAN] Exposed Global Config
- `5f95b86` - clean before GLOBALCONFIG
- `53e3802` - [clean] no idle in walls
- `2d1d6cc` - [CLEAN] idle bousculade OK
- `d40e27d` - CLEAN TWEAKS

---

## Patterns de conception clés

1. **Global Singletons:** Instances statiques pour SteeringSystem, AgentManager, GlobalConfig
2. **Reference Counting:** Flowfields trackent refcount pour suppression sécurisée
3. **Spatial Acceleration:** Hash grid pour requêtes O(1)
4. **Force-Based Steering:** Sommation vectorielle de comportements multiples
5. **Native Wrapping:** Cœur C++ avec couche Godot (séparation propre)
6. **Group-Based Control:** Gestion RTS de groupes d'unités
7. **Dynamic Flowfields:** Calcul par objectif pour navigation flexible

---

## Résumé pour analyse IA

### Type de projet
Système de navigation sophistiqué pour foules combinant:
- **Cœur C++ haute performance** pour pathfinding et steering
- **Intégration Godot** pour prototypage rapide et gameplay visuel
- **Technique Flowfield** pour pathfinding multi-agent scalable
- **Modèle de forces hiérarchique** équilibrant évitement de murs, séparation, et poursuite d'objectif
- **Gestion de groupes** permettant contrôle RTS d'unités

### Points d'entrée pour modification

#### Ajout de comportements steering:
- Fichier: [extensions/flowfield/steering/steering_system.cpp](extensions/flowfield/steering/steering_system.cpp)
- Fonction: `SteeringSystem::update_all()`
- Ajouter force dans la combinaison existante

#### Modification configuration:
- Fichier: [extensions/flowfield/core/global_config.h](extensions/flowfield/core/global_config.h)
- Struct: `GlobalConfig`
- Exposer via [extensions/flowfield/native/global_config_native.cpp](extensions/flowfield/native/global_config_native.cpp)

#### Ajout de fonctionnalités GDScript:
- Agents: [character/character.gd](character/character.gd)
- Contrôles: [controls/controls.gd](controls/controls.gd)
- Coordinateur: [pathfinder/FlowFieldCode.gd](pathfinder/FlowFieldCode.gd)

#### Modification algorithme flowfield:
- Fichier: [extensions/flowfield/flow/flow_field.cpp](extensions/flowfield/flow/flow_field.cpp)
- Fonction: `FlowField::compute()`

### Architecture propre
Le projet sépare clairement les responsabilités:
- Extension C++ gère toute la physique/navigation
- GDScript gère la logique de jeu, input, et setup de scène
- Les wrappers natifs font le pont entre les deux mondes

### Extensibilité
Conception modulaire facilitant l'ajout de:
- Nouveaux comportements steering
- Nouveaux types d'agents
- Nouvelles configurations
- Nouvelles mécaniques de gameplay

Le projet est bien organisé, activement maintenu, et conçu pour l'extensibilité (comme en témoigne la feature smash force à venir).
