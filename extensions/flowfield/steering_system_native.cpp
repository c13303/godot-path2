// ============================================================================
// SteeringSystemNative
// Système de steering natif pour Godot 4.x
// Gestion des agents 2D suivant un flowfield avec évitement local, séparation,
// détection d'immobilité, blocage et réactivation.
// ============================================================================

#include "steering_system_native.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

// ============================================================================
// Méthodes d'enregistrement Godot
// ============================================================================

void SteeringSystemNative::_bind_methods()
{
	// Liaison des méthodes accessibles depuis GDScript
	ClassDB::bind_method(D_METHOD("register_agent", "agent", "group_id", "max_speed"), &SteeringSystemNative::register_agent);
	ClassDB::bind_method(D_METHOD("unregister_agent", "agent"), &SteeringSystemNative::unregister_agent);
	ClassDB::bind_method(D_METHOD("set_flowfield_for_group", "group_id", "flowfield"), &SteeringSystemNative::set_flowfield_for_group);
	ClassDB::bind_method(D_METHOD("update_all_agents", "delta"), &SteeringSystemNative::update_all_agents);
	ClassDB::bind_method(D_METHOD("set_grid", "g"), &SteeringSystemNative::set_grid);
	ClassDB::bind_method(D_METHOD("get_grid"), &SteeringSystemNative::get_grid);

	// Propriété "grid" exposée à l’éditeur Godot
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "grid", PROPERTY_HINT_RESOURCE_TYPE, "SpatialGridNative"), "set_grid", "get_grid");
}

SteeringSystemNative::SteeringSystemNative() {}
SteeringSystemNative::~SteeringSystemNative() {}

// ============================================================================
// Constantes physiques et comportementales globales
// ============================================================================

namespace
{
	// Force de suivi du flowfield
	const double FLOW_WEIGHT = 1.0;

	// Force de séparation inter-agent
	const double SEPARATION_WEIGHT = 0.5;

	// Répulsion des murs
	const double WALL_REPULSION_WEIGHT = 0.6;

	// Rayon d'interaction pour séparation douce
	const double NEIGHBOR_RADIUS_SOFT = 20.0;

	// Rayon plus strict pour séparation rapprochée
	const double NEIGHBOR_RADIUS_HARD = 16.0;

	// Gestion du ralentissement à l’arrivée
	const double SLOW_RADIUS_FACTOR = 2.5;
	const double ARRIVAL_EPS_FACTOR = 0.15;

	// Diverses constantes liées au glissement / contournement
	const double SLIDE_DECAY_PER_STEP = 2;
	const double SLIDE_PROBE_DISTANCE = 0.6;
	const bool DIAGONAL_PROBE_ENABLE = true;

	// Jitter aléatoire (pour casser les symétries)
	const double JITTER_AMPLITUDE = 0.5;
	const double JITTER_COOLDOWN = 0.25;
	const bool JITTER_ONLY_NEAR_WALL = true;

	// Limites des micro-déplacements
	const double MAX_MICRO_STEP_TILE = 0.4;
	const double PROBE_DIST_TILE = 0.5;

	// Critères d'immobilité (blocage)
	const int IMMOBILE_FRAMES_THRESHOLD = 25;
	const double MIN_MOVEMENT_THRESHOLD_FACTOR = 0.03;
	const double MAX_STAGNATION_TIME = 4.0;

	// Gestion du "score de blocage" progressif
	const double BLOCK_SCORE_DECAY = 0.9;
	const double BLOCK_SCORE_INCREMENT = 0.3;
	const double BLOCK_SCORE_LIMIT = 3.0;

	// Facteur moyen de surface libre
	const double WALL_FACTOR_DEFAULT = 0.85;

	// Seuils de densité locale
	const int NEIGHBOR_CONGESTION_THRESHOLD = 6;
	const int VERY_CLOSE_BLOCK_COUNT = 3;
	const int CLOSE_BLOCK_COUNT = 5;

	// Aire moyenne et marge de sécurité pour un groupe
	const double AREA_PER_AGENT = 2.4;
	const double PADDING_TILES = 2.0;

	// Fréquence des logs de synthèse
	const double FRAME_SUMMARY_INTERVAL = 1.0;
}

// ============================================================================
// Enregistrement / désenregistrement des agents
// ============================================================================

void SteeringSystemNative::register_agent(Node2D *agent, int32_t group_id, double max_speed)
{
	if (!agent)
		return;
	if (agent_indices.count(agent))
		return;

	// Création d'une nouvelle structure agent
	AgentData data;
	data.node = agent;
	data.group_id = group_id;
	data.max_speed = max_speed;
	data.position = agent->get_global_position();
	data.velocity = Vector2();

	agents.push_back(data);
	agent_indices[agent] = (int32_t)agents.size() - 1;

	if (grid)
		grid->register_agent(agent);
}

void SteeringSystemNative::unregister_agent(Node2D *agent)
{
	if (!agent)
		return;
	auto it = agent_indices.find(agent);
	if (it == agent_indices.end())
		return;

	// Remplacement par le dernier élément pour éviter les trous
	int idx = it->second;
	int last = (int)agents.size() - 1;
	if (idx != last)
	{
		agents[idx] = agents[last];
		agent_indices[agents[idx].node] = idx;
	}
	agents.pop_back();
	agent_indices.erase(it);

	if (grid)
		grid->unregister_agent(agent);
}

// ============================================================================
// Gestion des dépendances extérieures : flowfield et grille spatiale
// ============================================================================

void SteeringSystemNative::set_flowfield_for_group(int32_t group_id, FlowField *ff)
{
	if (!ff)
		return;
	flowfields[group_id] = ff;
}

void SteeringSystemNative::set_grid(SpatialGridNative *g)
{
	grid = g;
}

// ============================================================================
// Calcul de la force de séparation entre agents
// ============================================================================

Vector2 SteeringSystemNative::compute_separation(Node2D *agent, double)
{
	if (!grid || !agent)
		return Vector2();

	// Collecte des voisins à proximité
	const double neighbor_radius = NEIGHBOR_RADIUS_SOFT;
	Vector2 pos = agent->get_global_position();
	TypedArray<Node2D> neighbors = grid->get_neighbors(pos, 2);

	Vector2 sep;
	int count = 0;

	for (int i = 0; i < neighbors.size(); i++)
	{
		Node2D *n = Object::cast_to<Node2D>(neighbors[i]);
		if (!n || n == agent)
			continue;

		Vector2 diff = pos - n->get_global_position();
		double dist = diff.length();
		if (dist > 0.0 && dist < neighbor_radius)
		{
			double falloff = 1.0 - (dist / neighbor_radius);
			sep += diff.normalized() * falloff;
			count++;
		}
	}
	if (count > 0)
		sep /= (double)count;
	if (sep == Vector2())
		return Vector2();
	return sep.normalized();
}

// ============================================================================
// Boucle principale d’update : mise à jour globale de tous les agents
// ============================================================================

void SteeringSystemNative::update_all_agents(double delta)
{
	if (agents.empty())
		return;

	_snapshot_agent_states();      // Met à jour les positions et vitesses enregistrées
	_process_agent_movements(delta); // Applique les forces et déplacements
	_check_flowfield_updates();      // Synchronise les changements de flowfield
}

// ============================================================================
// Capture de l’état actuel des agents (position, vitesse, historique)
// ============================================================================

void SteeringSystemNative::_snapshot_agent_states()
{
	for (auto &a : agents)
	{
		if (!a.node)
			continue;

		a.position = a.node->get_global_position();
		Variant v = a.node->get("velocity");
		a.velocity = (v.get_type() == Variant::VECTOR2) ? (Vector2)v : Vector2();

		// Historique des positions récentes (pour détection d’immobilité)
		if (a.pos_history.size() > 60)
			a.pos_history.pop_front();
		a.pos_history.push_back(a.position);

		// Réinitialisation si l’agent est marqué comme arrivé
		if (a.arrived)
		{
			a.progress_sum = 0.0;
			a.progress_timer = 0.0;
			a.parked = false;
			a.pos_history.clear();
			continue;
		}
	}
}

// ============================================================================
// Traitement complet des déplacements et états dynamiques des agents
// ============================================================================

void SteeringSystemNative::_process_agent_movements(double delta)
{
	int arrived_this_frame = 0;
	int immobile_candidates = 0;
	int fully_blocked = 0;
	int parked_count = 0;
	int reactivated = 0;

	for (auto &a : agents)
	{
		if (!a.node)
			continue;
		if (a.arrived)
			continue;

		// Récupération du flowfield du groupe
		FlowField *ff = flowfields.count(a.group_id) ? flowfields[a.group_id] : nullptr;
		if (!ff || !ff->is_ready())
			continue;

		// ----- Gestion de l’état "parked" (agent temporairement inactif) -----
		if (a.parked)
		{
			bool should_reactivate = false;

			// Cas 1 : flowfield mis à jour
			if (ff->flow_version() != 0 && !ff->sample_dir_world(a.position).is_zero_approx())
				should_reactivate = true;

			// Cas 2 : densité locale faible
			if (!should_reactivate && grid)
			{
				TypedArray<Node2D> nearby = grid->get_neighbors(a.position, 2);
				if (nearby.size() < 4)
					should_reactivate = true;
			}

			// Cas 3 : mouvement spontané détecté
			if (!should_reactivate && a.velocity.length() > 0.15 * a.max_speed)
				should_reactivate = true;

			// Si toujours bloqué : gèle l’agent
			if (!should_reactivate)
			{
				a.node->set("velocity", Vector2());
				a.node->set_process(false);
				a.node->set_physics_process(false);
				parked_count++;
				continue;
			}
			else
			{
				// Réactivation
				a.parked = false;
				a.node->set_process(true);
				a.node->set_physics_process(true);
				reactivated++;
			}
		}

		// ----- Vérification d'arrivée directe -----
		if (_check_direct_arrival(a, *ff))
		{
			arrived_this_frame++;
			continue;
		}

		// ----- Vérifie la direction du flowfield -----
		Vector2 flow_dir = ff->sample_dir_world(a.position);
		if (flow_dir == Vector2())
		{
			_mark_agent_arrived(a);
			arrived_this_frame++;
			continue;
		}

		// ----- Gestion d’immobilité prolongée / blocage -----
		bool stopped = _check_immobility_and_block(a, *ff);
		if (stopped)
		{
			arrived_this_frame++;
			fully_blocked++;
			continue;
		}
		else
		{
			int counter = (int)a.node->get_meta("_immobile_counter");
			if (counter > 0)
				immobile_candidates++;
		}

		// ----- Application des forces de steering -----
		_apply_steering_and_movement(a, *ff, delta);
	}
}

// ============================================================================
// Vérifie si un agent est déjà arrivé à destination
// ============================================================================

bool SteeringSystemNative::_check_direct_arrival(AgentData &a, FlowField &ff)
{
	Vector2 goal_pos = ff.cell_to_world(ff.current_goal_cell());
	Vector2i goal_cell = ff.current_goal_cell();
	Vector2i cur_cell = ff.world_to_cell(a.position);
	double dist = a.position.distance_to(goal_pos);
	const double tile_px = (double)ff.get_tile_size().x;

	if (cur_cell == goal_cell || dist <= tile_px * ARRIVAL_EPS_FACTOR)
	{
		_mark_agent_arrived(a);
		return true;
	}
	return false;
}

// ============================================================================
// Calcule le rayon de zone d’arrivée, définit à quelle distance du but un agent peut être considéré comme étant arrivé.
// ============================================================================

double SteeringSystemNative::_compute_goal_radius_px(int group_size, double tile_px, double wall_factor)
{
	if (group_size <= 0)
		group_size = 1;
	if (wall_factor <= 0.1)
		wall_factor = 0.1;

	double effective_cells = (group_size * AREA_PER_AGENT) / wall_factor;
	double radius_tiles = Math::sqrt(effective_cells / Math_PI) + PADDING_TILES;
	return radius_tiles * tile_px;
}

// ============================================================================
// Détection d’immobilité, blocage et passage en état "parked"
// Gère la stagnation prolongée, le scoring de blocage et la sortie automatique
// ============================================================================

bool SteeringSystemNative::_check_immobility_and_block(AgentData &a, FlowField &ff)
{
	const double tile_px = (double)ff.get_tile_size().x;
	const double min_move = tile_px * MIN_MOVEMENT_THRESHOLD_FACTOR;
	const double wall_factor = WALL_FACTOR_DEFAULT;

	Vector2 goal_pos = ff.cell_to_world(ff.current_goal_cell());
	double dist = a.position.distance_to(goal_pos);

	// ----- Taille du groupe (pour zone d'arrivée adaptative) -----
	int group_size = 0;
	for (auto &ag : agents)
		if (ag.group_id == a.group_id)
			group_size++;

	double goal_radius = _compute_goal_radius_px(group_size, tile_px, wall_factor);
	bool is_in_goal_zone = dist < goal_radius;

	// ----- Détection de congestion locale -----
	bool is_in_congestion = false;
	if (grid)
	{
		TypedArray<Node2D> nearby = grid->get_neighbors(a.position, 2);
		if (nearby.size() > NEIGHBOR_CONGESTION_THRESHOLD)
			is_in_congestion = true;
	}

	// ----- Calcul du progrès signé dans la direction du flow -----
	Vector2 flow_dir = ff.sample_dir_world(a.position).normalized();
	if (flow_dir == Vector2())
		return false;

	// Analyse de déplacement sur les positions récentes
	if (a.pos_history.size() >= 2)
	{
		Vector2 last_pos = a.pos_history.back();
		Vector2 prev_pos = a.pos_history.front();
		Vector2 delta = last_pos - prev_pos;
		double progress = delta.dot(flow_dir);
		a.progress_sum += progress;
		a.progress_timer += get_process_delta_time();

		// Fenêtre de temps de référence (3s)
		const double PROGRESS_WINDOW = 3.0;
		if (a.progress_timer > PROGRESS_WINDOW)
		{
			double v_avg = a.velocity.length();
			const double V_MIN = 0.15 * a.max_speed;
			const double EPS_PROG = 0.6 * tile_px;

			// Si aucun progrès mesurable + vitesse faible → parking
			if (a.progress_sum < EPS_PROG && v_avg < V_MIN)
				a.parked = true;
			else
				a.parked = false;

			a.progress_sum = 0.0;
			a.progress_timer = 0.0;
		}
	}

	// ----- Si agent non congestionné ni proche du but → réinitialise -----
	if (!(is_in_goal_zone || is_in_congestion))
	{
		a.node->set_meta("_immobile_counter", 0);
		a.node->set_meta("_block_score", 0.0);
		a.node->set_meta("_stagnation_time", 0.0);
		return false;
	}

	// ----- Initialisation des métadonnées locales -----
	if (!a.node->has_meta("_immobile_counter"))
		a.node->set_meta("_immobile_counter", 0);
	if (!a.node->has_meta("_block_score"))
		a.node->set_meta("_block_score", 0.0);
	if (!a.node->has_meta("_stagnation_time"))
		a.node->set_meta("_stagnation_time", 0.0);
	if (!a.node->has_meta("_last_pos"))
		a.node->set_meta("_last_pos", a.position);

	// ----- Calcul des déplacements récents -----
	int immobile_frames = (int)a.node->get_meta("_immobile_counter");
	Vector2 last_pos = (Vector2)a.node->get_meta("_last_pos");
	double distance_moved = a.position.distance_to(last_pos);
	a.node->set_meta("_last_pos", a.position);

	double block_score = (double)a.node->get_meta("_block_score");
	double stagnation_time = (double)a.node->get_meta("_stagnation_time");

	// ----- Comptage d’immobilité et stagnation -----
	if (distance_moved < min_move)
	{
		immobile_frames++;
		stagnation_time += get_process_delta_time();
	}
	else
	{
		immobile_frames = 0;
		stagnation_time = 0.0;
	}

	a.node->set_meta("_immobile_counter", immobile_frames);
	a.node->set_meta("_stagnation_time", stagnation_time);

	// ----- Mise à jour du score de blocage -----
	if (is_in_goal_zone && is_in_congestion && immobile_frames > IMMOBILE_FRAMES_THRESHOLD / 2)
		block_score += BLOCK_SCORE_INCREMENT;
	else
		block_score *= BLOCK_SCORE_DECAY;

	a.node->set_meta("_block_score", block_score);

	// ----- Condition finale : blocage confirmé -----
	if ((block_score > BLOCK_SCORE_LIMIT && immobile_frames >= IMMOBILE_FRAMES_THRESHOLD) || stagnation_time > MAX_STAGNATION_TIME)
	{
		_mark_agent_arrived(a);
		return true;
	}

	return false;
}

// ============================================================================
// Vérifie si un agent est entièrement bloqué par ses voisins
// ============================================================================

bool SteeringSystemNative::_is_fully_blocked(AgentData &a, FlowField &ff)
{
	if (!grid)
		return false;

	const double tile_px = (double)ff.get_tile_size().x;

	TypedArray<Node2D> nearby = grid->get_neighbors(a.position, 2);
	int close_neighbors = 0;
	int very_close = 0;

	for (int i = 0; i < nearby.size(); i++)
	{
		Node2D *n = Object::cast_to<Node2D>(nearby[i]);
		if (!n || n == a.node)
			continue;

		double d = a.position.distance_to(n->get_global_position());
		if (d < tile_px * 0.9)
			very_close++;
		else if (d < tile_px * 1.4)
			close_neighbors++;
	}

	// Bloqué si plusieurs voisins en contact proche
	bool blocked = (very_close >= VERY_CLOSE_BLOCK_COUNT) || (close_neighbors >= CLOSE_BLOCK_COUNT);
	return blocked;
}

// ============================================================================
// Marque un agent comme arrivé et désactive son traitement
// ============================================================================

void SteeringSystemNative::_mark_agent_arrived(AgentData &a)
{
	a.arrived = true;
	a.velocity = Vector2();
	a.node->set("velocity", a.velocity);
	a.node->set_process(false);
	a.node->set_physics_process(false);
	if (grid)
		grid->update_agent(a.node);
}

// ============================================================================
// Cœur du steering : application des forces et déplacement progressif
// ============================================================================

void SteeringSystemNative::_apply_steering_and_movement(AgentData &a, FlowField &ff, double delta)
{
	const double tile_px = (double)ff.get_tile_size().x;

	// ----- Extraction des directions principales -----
	Vector2 flow_dir = ff.sample_dir_world(a.position);
	Vector2 wall_repulse;
	auto *floor_layer = ff.get_floor_layer();
	auto *wall_layer = ff.get_wall_layer();

	// ----- Atténuation du flow près du but -----
	Vector2 goal_pos = ff.cell_to_world(ff.current_goal_cell());
	double dist = a.position.distance_to(goal_pos);
	double goal_radius = tile_px * 10.0;
	double fade_factor = Math::pow(Math::clamp(dist / goal_radius, 0.0, 1.0), 2.0);
	Vector2 effective_flow = flow_dir * fade_factor;

	// ----- Répulsion des murs -----
	const double probe_dist = tile_px * PROBE_DIST_TILE;
	const Vector2 probes[4] = {
		Vector2((float)probe_dist, 0.0f),
		Vector2((float)-probe_dist, 0.0f),
		Vector2(0.0f, (float)probe_dist),
		Vector2(0.0f, (float)-probe_dist)};
	for (const auto &p : probes)
	{
		Vector2 probe_pos = a.position + p;
		Vector2i cell = ff.world_to_cell(probe_pos);
		bool has_wall = wall_layer && wall_layer->get_cell_tile_data(cell) != nullptr;
		if (has_wall)
		{
			double falloff = 1.0 - (p.length() / (tile_px * 0.8));
			wall_repulse -= p.normalized() * Math::clamp(falloff, 0.0, 1.0);
		}
	}
	if (wall_repulse != Vector2())
		wall_repulse = wall_repulse.normalized() * WALL_REPULSION_WEIGHT;

	// ----- Calcul de la densité locale -----
	double local_density = 0.0;
	if (grid)
	{
		TypedArray<Node2D> nearby = grid->get_neighbors(a.position, 2);
		for (int i = 0; i < nearby.size(); i++)
		{
			Node2D *n = Object::cast_to<Node2D>(nearby[i]);
			if (n && n != a.node)
			{
				double d = a.position.distance_to(n->get_global_position());
				if (d < NEIGHBOR_RADIUS_SOFT)
					local_density += 1.0;
			}
		}
	}
	double density_factor = Math::clamp(local_density / 6.0, 0.0, 1.0);

	// ----- Calcul du vecteur de séparation -----
	Vector2 sep = compute_separation(a.node, 20.0) * (1.0 + density_factor * 2.0);

	// ----- Combinaison des forces principales -----
	Vector2 combined_dir = (effective_flow * FLOW_WEIGHT + sep * SEPARATION_WEIGHT + wall_repulse).normalized();

	// ----- Calcul de la vitesse cible -----
	double friction_factor = 1.0;
	if (dist < goal_radius)
		friction_factor -= 0.3 * density_factor * (1.0 - fade_factor);
	double lerp_speed = 0.18 * friction_factor;

	Vector2 desired_vel = combined_dir * a.max_speed;
	Vector2 new_velocity = a.velocity;

	// ----- Filtrage directionnel léger (aniso) -----
	double v_len = new_velocity.length();
	if (v_len > 1e-6)
	{
		Vector2 forward = new_velocity / (float)v_len;
		Vector2 desired_parallel = forward * desired_vel.dot(forward);
		Vector2 desired_lateral = desired_vel - desired_parallel;
		double lateral_response = 1.0 - 0.25 * density_factor;
		Vector2 filtered_target = desired_parallel + desired_lateral * (float)lateral_response;
		new_velocity = new_velocity.lerp(filtered_target, lerp_speed);
	}
	else
		new_velocity = new_velocity.lerp(desired_vel, lerp_speed);

	// ----- Ralentissement progressif à l’approche du but -----
	double slow_radius = tile_px * SLOW_RADIUS_FACTOR;
	if (dist < slow_radius)
	{
		double factor = Math::clamp(dist / slow_radius, 0.1, 1.0);
		new_velocity *= factor;
	}

	// ----- Simulation des micro-steps (collisions par axes) -----
	Vector2 total_move = new_velocity * (float)delta;
	const double max_step = tile_px * MAX_MICRO_STEP_TILE;
	double remain = total_move.length();
	int steps = (int)Math::ceil(remain / max_step);
	if (steps < 1)
		steps = 1;
	Vector2 step = total_move / (float)steps;

	for (int s = 0; s < steps; s++)
	{
		Vector2 trial = a.position + step;
		Vector2i cell = ff.world_to_cell(trial);
		bool has_floor = floor_layer && floor_layer->get_cell_tile_data(cell) != nullptr;
		bool has_wall = wall_layer && wall_layer->get_cell_tile_data(cell) != nullptr;

		if (has_floor && !has_wall)
		{
			a.position = trial;
			continue;
		}

		// Essais par axes si collision détectée
		Vector2 trial_x = a.position + Vector2(step.x, 0.0f);
		Vector2i cell_x = ff.world_to_cell(trial_x);
		bool ok_x = floor_layer && floor_layer->get_cell_tile_data(cell_x) != nullptr &&
					!(wall_layer && wall_layer->get_cell_tile_data(cell_x) != nullptr);

		Vector2 trial_y = a.position + Vector2(0.0f, step.y);
		Vector2i cell_y = ff.world_to_cell(trial_y);
		bool ok_y = floor_layer && floor_layer->get_cell_tile_data(cell_y) != nullptr &&
					!(wall_layer && wall_layer->get_cell_tile_data(cell_y) != nullptr);

		if (ok_x && !ok_y)
			a.position = trial_x;
		else if (ok_y && !ok_x)
			a.position = trial_y;
		else if (ok_x && ok_y)
			a.position = (Math::abs(step.x) >= Math::abs(step.y)) ? trial_x : trial_y;
		else
		{
			new_velocity = Vector2();
			break;
		}
	}

	// ----- Application du déplacement final -----
	a.velocity = new_velocity;
	a.node->set_global_position(a.position);
	a.node->set("velocity", a.velocity);
	a.node->set("z_index", int(a.position.y));

	if (grid)
		grid->update_agent(a.node);
}

// ============================================================================
// Vérifie les changements de flowfield et réinitialise les agents concernés
// ============================================================================

void SteeringSystemNative::_check_flowfield_updates()
{
	static std::unordered_map<int, int> last_version;

	for (auto &[gid, ff] : flowfields)
	{
		if (!ff)
			continue;

		int current_version = ff->flow_version();
		if (!last_version.count(gid))
			last_version[gid] = current_version;

		// Si le flowfield du groupe a changé → réinitialisation complète
		if (current_version != last_version[gid])
		{
			for (auto &a : agents)
			{
				if (a.group_id != gid || !a.node)
					continue;

				a.arrived = false;
				a.velocity = Vector2();
				a.node->set("velocity", a.velocity);
				a.node->set_process(true);
				a.node->set_physics_process(true);

				// Nettoyage des métadonnées d’état
				a.node->set_meta("_immobile_counter", 0);
				a.node->set_meta("_block_score", 0.0);
				a.node->set_meta("_stagnation_time", 0.0);
				a.node->set_meta("_last_pos", a.position);
			}

			last_version[gid] = current_version;
		}
	}
}
