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

/* propa*/

void SteeringSystemNative::update_all_agents(double delta)
{
	if (agents.empty())
		return;

	// Snapshot depuis la scène
	for (auto &a : agents)
	{
		if (!a.node)
			continue;
		a.position = a.node->get_global_position();
		Variant v = a.node->get("velocity");
		a.velocity = (v.get_type() == Variant::VECTOR2) ? (Vector2)v : Vector2();
	}

	for (auto &a : agents)
	{
		if (!a.node || a.arrived)
			continue;

		FlowField *ff = flowfields.count(a.group_id) ? flowfields[a.group_id] : nullptr;
		if (!ff || !ff->is_ready())
			continue;

		const Vector2 goal_pos = ff->cell_to_world(ff->current_goal_cell());
		const Vector2i goal_cell = ff->current_goal_cell();
		const Vector2i cur_cell = ff->world_to_cell(a.position);

		// Arrivée stricte uniquement si DANS la cell goal (pas de snap)
		if (cur_cell == goal_cell)
		{
			a.arrived = true;
			a.velocity = Vector2();
			a.node->set("velocity", a.velocity);
			// pas de repositionnement forcé
			if (grid)
				grid->update_agent(a.node);
			continue;
		}

		// 1) Lecture du flow
		Vector2 flow_dir = ff->sample_dir_world(a.position);
		if (flow_dir != Vector2())
			flow_dir = flow_dir.normalized();

		// 2) Séparation locale (existante)
		double speed = a.velocity.length();
		double t = Math::clamp(speed / a.max_speed, 0.0, 1.0);
		const double NEIGHBOR_RADIUS_SOFT = 20.0;
		const double NEIGHBOR_RADIUS_HARD = 16.0;
		double adaptive_radius = Math::lerp(NEIGHBOR_RADIUS_HARD, NEIGHBOR_RADIUS_SOFT, t);
		const double SEPARATION_WEIGHT = 1.0;
		Vector2 sep = compute_separation(a.node, adaptive_radius) * SEPARATION_WEIGHT;

		// 3) Répulsion mur douce (existante)
		Vector2 wall_repulse;
		{
			auto *floor_layer = ff->get_floor_layer();
			auto *wall_layer = ff->get_wall_layer();
			const double tile_px = (double)ff->get_tile_size().x;
			const double probe_dist = tile_px * 0.5;
			const Vector2 probes[4] = {
				Vector2((float)probe_dist, 0.0f),
				Vector2((float)-probe_dist, 0.0f),
				Vector2(0.0f, (float)probe_dist),
				Vector2(0.0f, (float)-probe_dist)};
			for (const auto &p : probes)
			{
				Vector2i c = ff->world_to_cell(a.position + p);
				bool has_wall = wall_layer && wall_layer->get_cell_tile_data(c) != nullptr;
				if (has_wall)
				{
					double falloff = 1.0 - (p.length() / (tile_px * 0.8));
					wall_repulse -= p.normalized() * Math::clamp(falloff, 0.0, 1.0);
				}
			}
			if (wall_repulse != Vector2())
				wall_repulse = wall_repulse.normalized() * 0.6;
		}

		// 4) Combinaison directionnelle
		const double FLOW_WEIGHT = 1.0;
		Vector2 combined = flow_dir * FLOW_WEIGHT + sep + wall_repulse;
		if (combined != Vector2())
			combined = combined.normalized();

		// 5) Dissipation simple (friction numérique)
		a.velocity *= 0.98;

		// 6) Facteur de densité locale → réduit la vitesse-cible sans forcer l’arrêt
		double density_factor = 0.0; // 0..0.5
		int ncount = 0;
		if (grid)
		{
			TypedArray<Node2D> near = grid->get_neighbors(a.position, 1); // 3x3 cellules
			ncount = (int)near.size();
			if (ncount > 6)
			{
				double x = Math::clamp((double)(ncount - 6) / 14.0, 0.0, 1.0);
				density_factor = 0.05 + 0.45 * x;
			}
		}

		// 7) Vitesse cible modulée par densité
		double target_speed = a.max_speed * (1.0 - density_factor);
		target_speed = Math::clamp(target_speed, a.max_speed * 0.20, a.max_speed);
		Vector2 target_vel = combined * (float)target_speed;

		// 8) Lissage vers la cible
		a.velocity = a.velocity.lerp(target_vel, 0.25);

		// 9) Ralentissement progressif à l’approche du but (rayon ~2 tiles)
		double dist_goal = a.position.distance_to(goal_pos);
		double slow_radius = ff->get_tile_size().x * 2.0;
		if (dist_goal < slow_radius)
		{
			double f = Math::clamp(dist_goal / slow_radius, 0.15, 1.0);
			a.velocity *= f;
		}

		// 10) Avancement conservatif + “slide” léger (prévention mur)
		{
			auto *floor_layer = ff->get_floor_layer();
			auto *wall_layer = ff->get_wall_layer();
			const double tile_px = (double)ff->get_tile_size().x;
			Vector2 total_move = a.velocity * (float)delta;
			const double max_step = tile_px * 0.4;
			double remain = (double)total_move.length();
			int steps = (int)Math::ceil(remain / max_step);
			if (steps < 1)
				steps = 1;
			Vector2 step = (steps > 0) ? (total_move / (float)steps) : Vector2();

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

				// axes séparés
				Vector2 trial_x = a.position + Vector2(step.x, 0);
				Vector2i cell_x = ff->world_to_cell(trial_x);
				bool ok_x = floor_layer && floor_layer->get_cell_tile_data(cell_x) != nullptr &&
							!(wall_layer && wall_layer->get_cell_tile_data(cell_x) != nullptr);

				Vector2 trial_y = a.position + Vector2(0, step.y);
				Vector2i cell_y = ff->world_to_cell(trial_y);
				bool ok_y = floor_layer && floor_layer->get_cell_tile_data(cell_y) != nullptr &&
							!(wall_layer && wall_layer->get_cell_tile_data(cell_y) != nullptr);

				if (ok_x && !ok_y)
				{
					a.position = trial_x;
					a.velocity *= 0.85;
					continue;
				}
				if (ok_y && !ok_x)
				{
					a.position = trial_y;
					a.velocity *= 0.85;
					continue;
				}
				if (ok_x && ok_y)
				{
					if (Math::abs(step.x) >= Math::abs(step.y))
						a.position = trial_x;
					else
						a.position = trial_y;
					a.velocity *= 0.85;
					continue;
				}

				// bloqué sur ce micro-pas
				a.velocity = Vector2();
				break;
			}
		}


		// 11) Critère d’“arrivé” doux : vitesse faible soutenue + densité
		{
			const double V_EPS = a.max_speed * 0.25; // 25% de la Vmax
			const int FRAMES_REQ = 6;				 // persistance minimale
			int slow_frames = 0;
			Variant sv = a.node->get("_slow_frames");
			if (sv.get_type() == Variant::INT)
				slow_frames = (int)sv;

			if (a.velocity.length() < V_EPS && ncount >= 4)
				slow_frames++;
			else
				slow_frames = 0;

			if (slow_frames >= FRAMES_REQ)
			{
				a.arrived = true;
				a.velocity = Vector2();
				a.node->set("velocity", a.velocity);

				// Désactivation du node pour économiser et figer le comportement
				a.node->set_process(false);
				a.node->set_physics_process(false);

				if (grid)
					grid->unregister_agent(a.node);

				slow_frames = 0;
			}

			a.node->set("_slow_frames", slow_frames);
		}

		// Application scène
		a.node->set_global_position(a.position);
		a.node->set("velocity", a.velocity);
		a.node->set("z_index", int(a.position.y));

		if (grid)
			grid->update_agent(a.node);
	}

	// Reset des arrivés si version du flow change
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
			for (auto &a : agents)
				if (a.group_id == gid)
					a.arrived = false;
			last_version[gid] = current_version;
		}
	}

	// Compteur
	int arrived_count = 0;
	for (auto &a : agents)
		if (a.arrived)
			arrived_count++;
	if ((int)UtilityFunctions::randf_range(0, 100) < 2)
		UtilityFunctions::print("Agents arrived:", arrived_count, "/", (int)agents.size());
}
