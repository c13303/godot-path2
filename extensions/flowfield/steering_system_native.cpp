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

bool SteeringSystemNative::check_propagation(AgentData &a, FlowField *ff)
{
	if (!grid || !ff || !a.node)
		return false;

	TypedArray<Node2D> nearby = grid->get_neighbors(a.position, 2);
	double stop_dist = ff->get_tile_size().x * 0.9;

	for (int i = 0; i < nearby.size(); i++)
	{
		Node2D *n = Object::cast_to<Node2D>(nearby[i]);
		if (!n || n == a.node)
			continue;

		int32_t idx = agent_indices.count(n) ? agent_indices[n] : -1;
		if (idx < 0)
			continue;

		AgentData &other = agents[idx];
		if (other.arrived && a.position.distance_to(other.position) <= stop_dist)
			return true;
	}

	return false;
}

void SteeringSystemNative::update_all_agents(double delta)
{
	if (agents.empty())
		return;

	// --- Étape 1 : lecture des données Godot (snapshot) ---
	for (auto &a : agents)
	{
		if (!a.node)
			continue;
		a.position = a.node->get_global_position();
		Variant v = a.node->get("velocity");
		if (v.get_type() == Variant::VECTOR2)
			a.velocity = (Vector2)v;
		else
			a.velocity = Vector2();
	}

	// --- Étape 2 : boucle de mise à jour du mouvement ---
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

		// --- Arrivée : check distance + epsilon ---
		double arrive_eps = ff->get_tile_size().x * 0.15;
		double dist = a.position.distance_to(goal_pos);
		if (cur_cell == goal_cell || dist <= arrive_eps)
		{
			a.arrived = true;
			a.velocity = Vector2();
			a.node->set("velocity", Vector2());
			a.node->set_global_position(ff->cell_to_world(goal_cell));
			if (grid)
				grid->update_agent(a.node);
			continue;
		}

		// --- Propagation d'arrêt ---
		if (check_propagation(a, ff))
		{
			a.arrived = true;
			a.velocity = Vector2();
			a.node->set("velocity", a.velocity);
			continue;
		}

		// --- Lecture de direction ---
		Vector2 flow_dir = ff->sample_dir_world(a.position);

		// --- Répulsion mur douce ---
		Vector2 wall_repulse;
		if (ff)
		{
			auto *floor_layer = ff->get_floor_layer();
			auto *wall_layer = ff->get_wall_layer();
			const double tile_px = (double)ff->get_tile_size().x;
			const double probe_dist = tile_px * 0.5;

			// Quatre directions cardinales
			const Vector2 probes[4] = {
				Vector2(probe_dist, 0),
				Vector2(-probe_dist, 0),
				Vector2(0, probe_dist),
				Vector2(0, -probe_dist)};

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
				wall_repulse = wall_repulse.normalized() * WALL_REPULSION_WEIGHT;
		}

		if (flow_dir == Vector2())
		{
			Vector2i cur = ff->world_to_cell(a.position);
			Vector2 alt_dir;
			const Vector2i offsets[4] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
			for (auto &d : offsets)
			{
				Vector2i c = cur + d;
				Vector2 v = ff->sample_dir_cell(c);
				if (v != Vector2())
				{
					alt_dir = v;
					break;
				}
			}
			if (alt_dir == Vector2())
			{
				Vector2 jitter = Vector2(
					UtilityFunctions::randf_range(-0.5, 0.5),
					UtilityFunctions::randf_range(-0.5, 0.5));
				alt_dir = jitter.normalized();
			}
			flow_dir = alt_dir;
		}

		// --- Rayon de séparation adaptatif selon la vitesse ---
		double speed = a.velocity.length();
		double t = Math::clamp(speed / a.max_speed, 0.0, 1.0);
		double adaptive_radius = Math::lerp(NEIGHBOR_RADIUS_HARD, NEIGHBOR_RADIUS_SOFT, t);

		// --- Steering lissé et fluide ---
		Vector2 sep = compute_separation(a.node, adaptive_radius) * SEPARATION_WEIGHT;
		Vector2 combined = (flow_dir * FLOW_WEIGHT + sep + wall_repulse).normalized();
		Vector2 target_dir = combined;

		a.velocity = a.velocity.lerp(target_dir * a.max_speed, 0.25);

		// Freinage progressif à l'approche du but
		double slow_radius = ff->get_tile_size().x * 2.0;
		if (dist < slow_radius)
		{
			double factor = Math::clamp(dist / slow_radius, 0.1, 1.0);
			a.velocity *= factor;
		}

		// --- Prévention douce contre les murs (avant mouvement) ---
		if (ff)
		{
			Vector2 next_pos = a.position + a.velocity.normalized() * ff->get_tile_size().x * 0.5;
			Vector2i next_cell = ff->world_to_cell(next_pos);

			auto *floor_layer = ff->get_floor_layer();
			auto *wall_layer = ff->get_wall_layer();

			bool has_floor = floor_layer && floor_layer->get_cell_tile_data(next_cell) != nullptr;
			bool has_wall = wall_layer && wall_layer->get_cell_tile_data(next_cell) != nullptr;

			if (!has_floor || has_wall)
			{
				// Lissage : ralentit et glisse tangentiellement
				Vector2 normal = Vector2(-a.velocity.y, a.velocity.x).normalized();

				// Test du côté gauche et droit pour choisir la direction la plus libre
				Vector2i left_cell = ff->world_to_cell(a.position + normal * ff->get_tile_size().x * 0.6);
				Vector2i right_cell = ff->world_to_cell(a.position - normal * ff->get_tile_size().x * 0.6);

				bool left_free = floor_layer && floor_layer->get_cell_tile_data(left_cell) != nullptr &&
								 (!wall_layer || wall_layer->get_cell_tile_data(left_cell) == nullptr);
				bool right_free = floor_layer && floor_layer->get_cell_tile_data(right_cell) != nullptr &&
								  (!wall_layer || wall_layer->get_cell_tile_data(right_cell) == nullptr);

				if (left_free && !right_free)
					a.velocity = (a.velocity + normal * 0.3).normalized() * a.velocity.length() * 0.7;
				else if (right_free && !left_free)
					a.velocity = (a.velocity - normal * 0.3).normalized() * a.velocity.length() * 0.7;
				else
					a.velocity *= 0.6; // amorti si les deux côtés sont bouchés
			}
		}

		// --- Détection murale anticipée (pré-mouvement) ---

		// --- Avancement conservatif + slide contre les murs ---
		if (ff)
		{
			auto *floor_layer = ff->get_floor_layer();
			auto *wall_layer = ff->get_wall_layer();

			const double tile_px = (double)ff->get_tile_size().x;
			Vector2 total_move = a.velocity * (float)delta;

			// Taille max d’un micro-pas (<= 0.4 tuile) pour ne jamais "sauter" une cellule
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
					// Avance validée
					a.position = trial;
					continue;
				}

				// Cellule bloquée : tentative de slide par axes
				// 1) Test axe X seul
				Vector2 trial_x = a.position + Vector2(step.x, 0.0f);
				Vector2i cell_x = ff->world_to_cell(trial_x);
				bool ok_x = floor_layer && floor_layer->get_cell_tile_data(cell_x) != nullptr &&
							!(wall_layer && wall_layer->get_cell_tile_data(cell_x) != nullptr);

				// 2) Test axe Y seul
				Vector2 trial_y = a.position + Vector2(0.0f, step.y);
				Vector2i cell_y = ff->world_to_cell(trial_y);
				bool ok_y = floor_layer && floor_layer->get_cell_tile_data(cell_y) != nullptr &&
							!(wall_layer && wall_layer->get_cell_tile_data(cell_y) != nullptr);

				if (ok_x && !ok_y)
				{
					a.position = trial_x;
					a.velocity *= SLIDE_DECAY_PER_STEP; // amorti du slide
					continue;
				}
				if (ok_y && !ok_x)
				{
					a.position = trial_y;
					a.velocity *= SLIDE_DECAY_PER_STEP;
					continue;
				}
				if (ok_x && ok_y)
				{
					if (Math::abs(step.x) >= Math::abs(step.y))
						a.position = trial_x;
					else
						a.position = trial_y;
					a.velocity *= SLIDE_DECAY_PER_STEP;
					continue;
				}

				// Option diagonale : test supplémentaire si activé
				if (DIAGONAL_PROBE_ENABLE)
				{
					const Vector2 diagonals[4] = {
						Vector2(step.x, step.y),
						Vector2(step.x, -step.y),
						Vector2(-step.x, step.y),
						Vector2(-step.x, -step.y)};

					for (const auto &d : diagonals)
					{
						Vector2 trial_diag = a.position + d;
						Vector2i cell_diag = ff->world_to_cell(trial_diag);
						bool ok_diag = floor_layer && floor_layer->get_cell_tile_data(cell_diag) != nullptr &&
									   !(wall_layer && wall_layer->get_cell_tile_data(cell_diag) != nullptr);
						if (ok_diag)
						{
							a.position = trial_diag;
							a.velocity *= SLIDE_DECAY_PER_STEP * 0.9; // amorti plus fort sur diagonale
							break;
						}
					}
				}

				// Aucune issue sur ce micro-pas : on stoppe le mouvement restant
				a.velocity = Vector2();
				break;
			}
		}
		else
		{
			// Pas de FF : fallback mouvement brut
			a.position += a.velocity * delta;
		}

		// --- Mise à jour Godot ---
		a.node->set_global_position(a.position);
		a.node->set("velocity", a.velocity);
		a.node->set("z_index", int(a.position.y));

		// --- Mise à jour grille spatiale ---
		if (grid)
			grid->update_agent(a.node);
	}

	// --- Étape 3 : reset des arrivés si flowfield changé ---
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
}
