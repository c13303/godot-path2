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

// --- Paramètres globaux de tuning ---
namespace
{
	const double FLOW_WEIGHT = 1.0;			  // influence du flowfield
	const double SEPARATION_WEIGHT = 1;		  // poids de la séparation entre agents
	const double WALL_REPULSION_WEIGHT = 0.6; // intensité de la répulsion murale douce

	const double NEIGHBOR_RADIUS_SOFT = 20.0; // rayon max de détection des voisins (pixels)
	const double NEIGHBOR_RADIUS_HARD = 16.0; // rayon min à basse vitesse (densité accrue)

	const double SLOW_RADIUS_FACTOR = 2.0;		// distance de ralentissement avant but (× taille tuile)
	const double ARRIVAL_EPS_FACTOR = 0.15;		// tolérance de distance pour considérer un agent arrivé
	const double STOP_PROPAGATION_FACTOR = 0.9; // distance d’influence d’un agent arrêté (× tuile)

	const double SLIDE_DECAY_PER_STEP = 0.85; // amorti du slide à chaque micro-pas
	const double SLIDE_PROBE_DISTANCE = 0.6;  // distance latérale testée pour le slide (× tuile)
	const bool DIAGONAL_PROBE_ENABLE = true;  // active la recherche diagonale lors du contournement

	const double JITTER_AMPLITUDE = 0.5;	 // intensité du léger bruit directionnel
	const double JITTER_COOLDOWN = 0.25;	 // délai minimal entre deux perturbations (s)
	const bool JITTER_ONLY_NEAR_WALL = true; // n’applique le jitter que proche d’un mur

	const double MAX_MICRO_STEP_TILE = 0.4; // taille max d’un micro-pas (× taille tuile)
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
		/* UtilityFunctions::print("Registered agent via grid:", agent->get_instance_id()); */
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

Vector2 SteeringSystemNative::compute_separation(Node2D *agent, double /* neighbor_radius */)
{
	if (!grid || !agent)
		return Vector2();

	const double neighbor_radius = NEIGHBOR_RADIUS_SOFT;
	Vector2 pos = agent->get_global_position();
	TypedArray<Node2D> neighbors = grid->get_neighbors(pos, 2);

	Vector2 sep = Vector2();
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

	// --- Étape 1 : lecture snapshot des données Godot ---
	for (auto &a : agents)
	{
		if (!a.node)
			continue;
		a.position = a.node->get_global_position();
		Variant v = a.node->get("velocity");
		a.velocity = (v.get_type() == Variant::VECTOR2) ? (Vector2)v : Vector2();
	}

	// --- Étape 2 : mise à jour du mouvement et des arrivées ---
	for (auto &a : agents)
	{
		if (a.arrived)
			continue;

		FlowField *ff = flowfields.count(a.group_id) ? flowfields[a.group_id] : nullptr;
		if (!ff || !ff->is_ready())
			continue;

		Vector2 goal_pos = ff->cell_to_world(ff->current_goal_cell());
		Vector2i goal_cell = ff->current_goal_cell();
		Vector2i cur_cell = ff->world_to_cell(a.position);
		double dist = a.position.distance_to(goal_pos);
		const double tile_px = (double)ff->get_tile_size().x;

		// --- Critère 1 : Dans la cellule but exacte ---
		double arrive_eps = tile_px * 0.15;
		if (cur_cell == goal_cell || dist <= arrive_eps)
		{
			a.arrived = true;
			a.velocity = Vector2();
			a.node->set("velocity", a.velocity);
			a.node->set_process(false);
			a.node->set_physics_process(false);
			if (grid)
				grid->update_agent(a.node);
			continue;
		}

		// --- Critère 2 : Dans la zone neutre du flowfield ---
		Vector2 flow_dir = ff->sample_dir_world(a.position);
		if (flow_dir == Vector2())
		{
			a.arrived = true;
			a.velocity = Vector2();
			a.node->set("velocity", a.velocity);
			a.node->set_process(false);
			a.node->set_physics_process(false);
			if (grid)
				grid->update_agent(a.node);
			continue;
		}

		// --- Critère 3 : Proche du goal ET immobile longtemps ---
		const double ARRIVAL_RADIUS = tile_px * 8.0;
		const int IMMOBILE_FRAMES_NEAR_GOAL = 30;
		const double MIN_MOVEMENT_THRESHOLD = tile_px * 0.03;

		bool is_near_goal = dist < ARRIVAL_RADIUS;

		if (is_near_goal)
		{
			if (!a.node->has_meta("_immobile_near_goal"))
				a.node->set_meta("_immobile_near_goal", 0);
			if (!a.node->has_meta("_last_pos"))
				a.node->set_meta("_last_pos", a.position);

			int immobile_frames = (int)a.node->get_meta("_immobile_near_goal");
			Vector2 last_pos = (Vector2)a.node->get_meta("_last_pos");
			double distance_moved = a.position.distance_to(last_pos);
			a.node->set_meta("_last_pos", a.position);

			if (distance_moved < MIN_MOVEMENT_THRESHOLD)
				immobile_frames++;
			else
				immobile_frames = 0;

			a.node->set_meta("_immobile_near_goal", immobile_frames);

			if (immobile_frames >= IMMOBILE_FRAMES_NEAR_GOAL)
			{
				a.arrived = true;
				a.velocity = Vector2();
				a.node->set("velocity", a.velocity);
				a.node->set_process(false);
				a.node->set_physics_process(false);
				if (grid)
					grid->update_agent(a.node);
				continue;
			}
		}
		else
		{
			// Loin du goal → reset le compteur
			if (a.node->has_meta("_immobile_near_goal"))
				a.node->set_meta("_immobile_near_goal", 0);
		}

		// --- Répulsion murs douce ---
		Vector2 wall_repulse;
		auto *floor_layer = ff->get_floor_layer();
		auto *wall_layer = ff->get_wall_layer();
		const double probe_dist = tile_px * 0.5;
		const Vector2 probes[4] = {
			Vector2((float)probe_dist, 0.0f),
			Vector2((float)-probe_dist, 0.0f),
			Vector2(0.0f, (float)probe_dist),
			Vector2(0.0f, (float)-probe_dist)};
		for (const auto &p : probes)
		{
			Vector2 probe_pos = a.position + p;
			Vector2i cell = ff->world_to_cell(probe_pos);
			bool has_wall = wall_layer && wall_layer->get_cell_tile_data(cell) != nullptr;
			if (has_wall)
			{
				double falloff = 1.0 - (p.length() / (tile_px * 0.8));
				wall_repulse -= p.normalized() * Math::clamp(falloff, 0.0, 1.0);
			}
		}
		if (wall_repulse != Vector2())
			wall_repulse = wall_repulse.normalized() * 0.6;

		// --- Steering et vitesse ---
		Vector2 sep = compute_separation(a.node, 20.0);
		Vector2 combined = (flow_dir * FLOW_WEIGHT + sep * SEPARATION_WEIGHT + wall_repulse * WALL_REPULSION_WEIGHT).normalized();

		a.velocity = a.velocity.lerp(combined * a.max_speed, 0.25);

		// Ralentissement à l'approche du but
		double slow_radius = tile_px * 2.0;
		if (dist < slow_radius)
		{
			double factor = Math::clamp(dist / slow_radius, 0.1, 1.0);
			a.velocity *= factor;
		}

		// --- Déplacement micro-step ---
		Vector2 total_move = a.velocity * (float)delta;
		const double max_step = tile_px * 0.4;
		double remain = total_move.length();
		int steps = (int)Math::ceil(remain / max_step);
		if (steps < 1)
			steps = 1;
		Vector2 step = total_move / (float)steps;

		for (int s = 0; s < steps; s++)
		{
			Vector2 trial = a.position + step;
			Vector2i cell = ff->world_to_cell(trial);
			bool has_floor = floor_layer && floor_layer->get_cell_tile_data(cell) != nullptr;
			bool has_wall = wall_layer && wall_layer->get_cell_tile_data(cell) != nullptr;
			if (has_floor && !has_wall)
			{
				a.position = trial;
				continue;
			}
			Vector2 trial_x = a.position + Vector2(step.x, 0.0f);
			Vector2i cell_x = ff->world_to_cell(trial_x);
			bool ok_x = floor_layer && floor_layer->get_cell_tile_data(cell_x) != nullptr &&
						!(wall_layer && wall_layer->get_cell_tile_data(cell_x) != nullptr);
			Vector2 trial_y = a.position + Vector2(0.0f, step.y);
			Vector2i cell_y = ff->world_to_cell(trial_y);
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

		// --- Mise à jour Godot ---
		a.node->set_global_position(a.position);
		a.node->set("velocity", a.velocity);
		a.node->set("z_index", int(a.position.y));
		if (grid)
			grid->update_agent(a.node);
	}

	// --- Étape 3 : réinitialisation si FlowField mis à jour ---
	for (auto &[gid, ff] : flowfields)
	{
		if (!ff)
			continue;
		int current_version = ff->flow_version();
		static std::unordered_map<int, int> last_version;
		if (!last_version.count(gid))
			last_version[gid] = current_version;
		if (current_version != last_version[gid])
		{
			// Nouveau flowfield détecté → réinitialiser tous les agents du groupe
			for (auto &a : agents)
			{
				if (a.group_id == gid)
				{
					a.arrived = false;

					// Réactiver le node Godot
					if (a.node)
					{
						a.node->set_process(true);
						a.node->set_physics_process(true);

						// Reset des métadonnées de tracking
						if (a.node->has_meta("_immobile_near_goal"))
							a.node->set_meta("_immobile_near_goal", 0);
						if (a.node->has_meta("_last_pos"))
							a.node->set_meta("_last_pos", a.position);
					}
				}
			}
			last_version[gid] = current_version;
		}
	}

	// --- Étape 4 : affichage compteur ---
	int arrived_count = 0;
	for (auto &a : agents)
		if (a.arrived)
			arrived_count++;
}