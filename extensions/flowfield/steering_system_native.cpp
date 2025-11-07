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

Vector2 SteeringSystemNative::compute_separation(Node2D *agent, double neighbor_radius)
{
	if (!grid || !agent)
		return Vector2();

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

		// --- Steering lissé et fluide ---
		Vector2 sep = compute_separation(a.node, 32.0) * 1.2;
		Vector2 target_dir = (flow_dir * 1.0 + sep * 0.8).normalized();
		a.velocity = a.velocity.lerp(target_dir * a.max_speed, 0.25);

		// Freinage progressif à l'approche du but
		double slow_radius = ff->get_tile_size().x * 2.0;
		if (dist < slow_radius)
		{
			double factor = Math::clamp(dist / slow_radius, 0.1, 1.0);
			a.velocity *= factor;
		}

		// ✅ APPLICATION DU MOUVEMENT (LIGNE CRITIQUE)
		a.position += a.velocity * delta;

		// --- Correction anti-mur post-mouvement ---
		if (ff)
		{
			Vector2i check_cell = ff->world_to_cell(a.position);
			auto *floor_layer = ff->get_floor_layer();
			auto *wall_layer = ff->get_wall_layer();

			bool has_floor = floor_layer && floor_layer->get_cell_tile_data(check_cell) != nullptr;
			bool has_wall = wall_layer && wall_layer->get_cell_tile_data(check_cell) != nullptr;

			if (!has_floor || has_wall)
			{
				// Reculer et chercher un espace valide
				a.position -= a.velocity * delta;
				
				const Vector2i dirs[4] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
				bool moved = false;
				for (auto &d : dirs)
				{
					Vector2i c2 = check_cell + d;
					bool f_ok = floor_layer && floor_layer->get_cell_tile_data(c2) != nullptr;
					bool w_ok = !(wall_layer && wall_layer->get_cell_tile_data(c2) != nullptr);
					if (f_ok && w_ok)
					{
						a.position = ff->cell_to_world(c2);
						moved = true;
						break;
					}
				}
				if (!moved)
				{
					a.velocity = Vector2();
				}
			}
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
