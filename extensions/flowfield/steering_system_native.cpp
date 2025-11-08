#include "steering_system_native.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void SteeringSystemNative::_bind_methods()
{
	ClassDB::bind_method(D_METHOD("register_agent", "agent", "group_id", "max_speed"), &SteeringSystemNative::register_agent);
	ClassDB::bind_method(D_METHOD("unregister_agent", "agent"), &SteeringSystemNative::unregister_agent);
	ClassDB::bind_method(D_METHOD("set_flowfield_for_group", "group_id", "flowfield"), &SteeringSystemNative::set_flowfield_for_group);
	ClassDB::bind_method(D_METHOD("update_all_agents", "delta"), &SteeringSystemNative::update_all_agents);
	ClassDB::bind_method(D_METHOD("set_grid", "g"), &SteeringSystemNative::set_grid);
	ClassDB::bind_method(D_METHOD("get_grid"), &SteeringSystemNative::get_grid);

	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "grid", PROPERTY_HINT_RESOURCE_TYPE, "SpatialGridNative"), "set_grid", "get_grid");
}

SteeringSystemNative::SteeringSystemNative() {}
SteeringSystemNative::~SteeringSystemNative() {}

namespace
{
	// --- Poids des forces principales ---
	const double FLOW_WEIGHT = 1.0;			  // Poids du flowfield : suivre la direction globale (1.0 = valeur de base)
	const double SEPARATION_WEIGHT = 0.5;	  // Évitement entre agents (trop haut → dispersion, trop bas → congestion)
	const double WALL_REPULSION_WEIGHT = 0.6; // Répulsion douce des murs (limite le frottement contre les parois)

	// --- Détection de voisins ---
	const double NEIGHBOR_RADIUS_SOFT = 20.0; // Rayon max pour éviter les voisins (px)
	const double NEIGHBOR_RADIUS_HARD = 16.0; // Rayon plus strict à basse vitesse (px) — pour densifier localement

	// --- Gestion de la vitesse et de l’arrivée ---
	const double SLOW_RADIUS_FACTOR = 2.5;	// Distance de ralentissement avant but (× taille tuile)
	const double ARRIVAL_EPS_FACTOR = 0.15; // Tolérance de distance pour considérer “arrivé” (× taille tuile)

	// --- Systèmes secondaires (contournement / oscillation) ---
	const double SLIDE_DECAY_PER_STEP = 2; // Amortissement du glissement (stabilise les micro-corrections)
	const double SLIDE_PROBE_DISTANCE = 0.6;  // Distance testée latéralement pour éviter blocage (× tuile)
	const bool DIAGONAL_PROBE_ENABLE = true;  // Permet de tester diagonales dans le contournement

	// --- Jitter (micro-variation aléatoire pour casser les symétries) ---
	const double JITTER_AMPLITUDE = 0.5;	 // Intensité du jitter directionnel
	const double JITTER_COOLDOWN = 0.25;	 // Délai min entre deux perturbations (s)
	const bool JITTER_ONLY_NEAR_WALL = true; // Applique jitter uniquement près des murs (évite bruit global)

	// --- Micro-déplacements ---
	const double MAX_MICRO_STEP_TILE = 0.4; // Fraction max de tuile par micro-step
	const double PROBE_DIST_TILE = 0.5;		// Distance latérale utilisée pour tester murs (× tuile)

	// --- Critères d’immobilité ---
	const int IMMOBILE_FRAMES_THRESHOLD = 25;		   // Nombre de frames consécutives sans bouger avant détection d’arrêt
	const double MIN_MOVEMENT_THRESHOLD_FACTOR = 0.03; // Mouvement min détectable (× taille tuile)
	const double MAX_STAGNATION_TIME = 4.0;			   // Temps max avant arrêt forcé (s) → évite stagnation éternelle

	// --- Score de blocage (mesure progressive de congestion) ---
	const double BLOCK_SCORE_DECAY = 0.9;	   // Décroissance du score par frame (0.9 = amorti rapide)
	const double BLOCK_SCORE_INCREMENT = 0.3; // Incrément par frame dans zone dense → plus haut = arrêt plus rapide
	const double BLOCK_SCORE_LIMIT = 3.0;	   // Score à partir duquel on stoppe définitivement l’agent

	// --- Paramètres de terrain ---
	const double WALL_FACTOR_DEFAULT = 0.85; // Ratio moyen de surface libre (1.0 = sans mur, 0.85 = ~15 % d’obstacles)

	// --- Densité locale ---
	const int NEIGHBOR_CONGESTION_THRESHOLD = 6; // Nb de voisins déclenchant la détection de congestion
	const int VERY_CLOSE_BLOCK_COUNT = 3;		 // Nb de voisins à moins d’une tuile → contact physique
	const int CLOSE_BLOCK_COUNT = 5;			 // Nb de voisins proches (<1.4 tuile) → zone dense

	// --- Zone d’objectif (adaptation à la taille du groupe) ---
	const double AREA_PER_AGENT = 2.4; // Aire moyenne par agent (en tuiles)
	const double PADDING_TILES = 2.0;  // Marge de sécurité autour du groupe cible

	// --- Log ---
	const double FRAME_SUMMARY_INTERVAL = 1.0; // Fréquence des logs de synthèse (s)
}

void SteeringSystemNative::register_agent(Node2D *agent, int32_t group_id, double max_speed)
{
	if (!agent)
		return;
	if (agent_indices.count(agent))
		return;

	AgentData data;
	data.node = agent;
	data.group_id = group_id;
	data.max_speed = max_speed;
	data.position = agent->get_global_position();
	data.velocity = Vector2();

	agents.push_back(data);
	agent_indices[agent] = (int32_t)agents.size() - 1;

	if (grid)
	{
		grid->register_agent(agent);
	}
}

void SteeringSystemNative::unregister_agent(Node2D *agent)
{
	if (!agent)
		return;
	auto it = agent_indices.find(agent);
	if (it == agent_indices.end())
		return;

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

Vector2 SteeringSystemNative::compute_separation(Node2D *agent, double)
{
	if (!grid || !agent)
		return Vector2();

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

void SteeringSystemNative::update_all_agents(double delta)
{
	if (agents.empty())
		return;

	_snapshot_agent_states();
	_process_agent_movements(delta);
	_check_flowfield_updates();
}

void SteeringSystemNative::_snapshot_agent_states()
{
	for (auto &a : agents)
	{
		if (!a.node)
			continue;
		a.position = a.node->get_global_position();
		Variant v = a.node->get("velocity");
		a.velocity = (v.get_type() == Variant::VECTOR2) ? (Vector2)v : Vector2();
	}
}

void SteeringSystemNative::_process_agent_movements(double delta)
{
	int arrived_this_frame = 0;
	int immobile_candidates = 0;
	int fully_blocked = 0;

	for (auto &a : agents)
	{
		if (!a.node)
			continue;
		if (a.arrived)
			continue;

		FlowField *ff = flowfields.count(a.group_id) ? flowfields[a.group_id] : nullptr;
		if (!ff || !ff->is_ready())
			continue;

		if (_check_direct_arrival(a, *ff))
		{
			arrived_this_frame++;
			continue;
		}

		Vector2 flow_dir = ff->sample_dir_world(a.position);
		if (flow_dir == Vector2())
		{
			_mark_agent_arrived(a);
			arrived_this_frame++;
			/* UtilityFunctions::print("Agent ", a.node->get_instance_id(), " arrived (neutral flow)"); */
			continue;
		}

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

		_apply_steering_and_movement(a, *ff, delta);
	}

	/* 	static double time_since_last_log = 0.0;
		time_since_last_log += delta;
		if (time_since_last_log >= FRAME_SUMMARY_INTERVAL)
		{
			UtilityFunctions::print("Frame summary → new arrivals:", arrived_this_frame,
									" | immobile candidates:", immobile_candidates,
									" | blocked:", fully_blocked);
			time_since_last_log = 0.0;
		} */
}

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

bool SteeringSystemNative::_check_immobility_and_block(AgentData &a, FlowField &ff)
{
	const double tile_px = (double)ff.get_tile_size().x;
	const double min_move = tile_px * MIN_MOVEMENT_THRESHOLD_FACTOR;
	const double wall_factor = WALL_FACTOR_DEFAULT;

	Vector2 goal_pos = ff.cell_to_world(ff.current_goal_cell());
	double dist = a.position.distance_to(goal_pos);

	int group_size = 0;
	for (auto &ag : agents)
		if (ag.group_id == a.group_id)
			group_size++;

	double goal_radius = _compute_goal_radius_px(group_size, tile_px, wall_factor);
	bool is_in_goal_zone = dist < goal_radius;

	bool is_in_congestion = false;
	if (grid)
	{
		TypedArray<Node2D> nearby = grid->get_neighbors(a.position, 2);
		if (nearby.size() > NEIGHBOR_CONGESTION_THRESHOLD)
			is_in_congestion = true;
	}

	if (!(is_in_goal_zone || is_in_congestion))
	{
		a.node->set_meta("_immobile_counter", 0);
		a.node->set_meta("_block_score", 0.0);
		a.node->set_meta("_stagnation_time", 0.0);
		return false;
	}

	if (!a.node->has_meta("_immobile_counter"))
		a.node->set_meta("_immobile_counter", 0);
	if (!a.node->has_meta("_block_score"))
		a.node->set_meta("_block_score", 0.0);
	if (!a.node->has_meta("_stagnation_time"))
		a.node->set_meta("_stagnation_time", 0.0);
	if (!a.node->has_meta("_last_pos"))
		a.node->set_meta("_last_pos", a.position);

	int immobile_frames = (int)a.node->get_meta("_immobile_counter");
	Vector2 last_pos = (Vector2)a.node->get_meta("_last_pos");
	double distance_moved = a.position.distance_to(last_pos);
	a.node->set_meta("_last_pos", a.position);

	double block_score = (double)a.node->get_meta("_block_score");
	double stagnation_time = (double)a.node->get_meta("_stagnation_time");

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

	if (is_in_goal_zone && is_in_congestion && immobile_frames > IMMOBILE_FRAMES_THRESHOLD / 2)
		block_score += BLOCK_SCORE_INCREMENT;
	else
		block_score *= BLOCK_SCORE_DECAY;

	a.node->set_meta("_block_score", block_score);

	if ((block_score > BLOCK_SCORE_LIMIT && immobile_frames >= IMMOBILE_FRAMES_THRESHOLD) || stagnation_time > MAX_STAGNATION_TIME)
	{
		/* 	UtilityFunctions::print("Agent ", a.node->get_instance_id(),
									" BLOCKED (dist=", dist,
									" / goal_radius=", goal_radius,
									" / score=", block_score,
									" / stagnation_time=", stagnation_time, ")"); */
		_mark_agent_arrived(a);
		return true;
	}

	return false;
}

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

	bool blocked = (very_close >= VERY_CLOSE_BLOCK_COUNT) || (close_neighbors >= CLOSE_BLOCK_COUNT);

	/* if (blocked)
		UtilityFunctions::print("Agent ", a.node->get_instance_id(), " → BLOCKED (", very_close, " very close, ", close_neighbors, " close)");
 */
	return blocked;
}

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


void SteeringSystemNative::_apply_steering_and_movement(AgentData &a, FlowField &ff, double delta)
{
	const double tile_px = (double)ff.get_tile_size().x;

	Vector2 flow_dir = ff.sample_dir_world(a.position);
	Vector2 wall_repulse;
	auto *floor_layer = ff.get_floor_layer();
	auto *wall_layer = ff.get_wall_layer();

	// --- Atténuation progressive du flow_dir près du but ---
	Vector2 goal_pos = ff.cell_to_world(ff.current_goal_cell());
	double dist = a.position.distance_to(goal_pos);
	double goal_radius = tile_px * 10.0;
	double fade_factor = Math::pow(Math::clamp(dist / goal_radius, 0.0, 1.0), 2.0);

	// Annulation du flow_dir uniquement dans la zone neutre
	Vector2 effective_flow = flow_dir * fade_factor;

	// --- Répulsion des murs ---
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

	// --- Calcul densité locale ---
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
	Vector2 sep = compute_separation(a.node, 20.0) * (1.0 + density_factor * 2.0);

	Vector2 combined = (effective_flow * FLOW_WEIGHT + sep * SEPARATION_WEIGHT + wall_repulse).normalized();

	// --- Friction adaptative uniquement proche du goal ---
	double friction_factor = 1.0;
	if (dist < goal_radius)
		friction_factor -= 0.3 * density_factor * (1.0 - fade_factor);

	double lerp_speed = 0.18 * friction_factor;
	a.velocity = a.velocity.lerp(combined * a.max_speed, lerp_speed);

	// --- Ralentissement naturel à l’approche du but ---
	double slow_radius = tile_px * SLOW_RADIUS_FACTOR;
	if (dist < slow_radius)
	{
		double factor = Math::clamp(dist / slow_radius, 0.1, 1.0);
		a.velocity *= factor;
	}

	Vector2 total_move = a.velocity * (float)delta;
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
			a.velocity = Vector2();
			break;
		}
	}

	a.node->set_global_position(a.position);
	a.node->set("velocity", a.velocity);
	a.node->set("z_index", int(a.position.y));
	if (grid)
		grid->update_agent(a.node);
}

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

		// Si le flowfield du groupe a changé → réinitialiser tous les agents du groupe
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

				// Réinitialisation complète des métadonnées de blocage
				a.node->set_meta("_immobile_counter", 0);
				a.node->set_meta("_block_score", 0.0);
				a.node->set_meta("_stagnation_time", 0.0);
				a.node->set_meta("_last_pos", a.position);
			}

			last_version[gid] = current_version;
			/* UtilityFunctions::print("Flowfield update detected → agents of group", gid, "fully reset."); */
		}
	}
}
