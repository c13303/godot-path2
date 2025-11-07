#include "spatial_grid_native.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <algorithm> // <-- nécessaire pour std::remove

using namespace godot;

static int64_t cell_hash(const Vector2i &c) {
	return (int64_t(c.x) << 32) ^ int64_t(c.y);
}

void SpatialGridNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("clear"), &SpatialGridNative::clear);
	ClassDB::bind_method(D_METHOD("register_agent", "agent"), &SpatialGridNative::register_agent);
	ClassDB::bind_method(D_METHOD("update_agent", "agent"), &SpatialGridNative::update_agent);
	ClassDB::bind_method(D_METHOD("unregister_agent", "agent"), &SpatialGridNative::unregister_agent);
	ClassDB::bind_method(D_METHOD("get_neighbors", "pos", "range_cells"), &SpatialGridNative::get_neighbors);
	ClassDB::bind_method(D_METHOD("set_cell_size", "s"), &SpatialGridNative::set_cell_size);
	ClassDB::bind_method(D_METHOD("get_cell_size"), &SpatialGridNative::get_cell_size);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "cell_size"), "set_cell_size", "get_cell_size");
}

SpatialGridNative::SpatialGridNative() {}
SpatialGridNative::~SpatialGridNative() {}

Vector2i SpatialGridNative::_cell(const Vector2 &p) const {
	return Vector2i((int)Math::floor(p.x / cell_size), (int)Math::floor(p.y / cell_size));
}

void SpatialGridNative::clear() {
	buckets.clear();
	last_cell.clear();
}

void SpatialGridNative::register_agent(Node2D *agent) {
	if (!agent) return;
	int64_t id = agent->get_instance_id();
	Vector2i c = _cell(agent->get_global_position());
	last_cell[id] = c;
	int64_t key = cell_hash(c);
	buckets[key].agents.push_back(agent);
}

void SpatialGridNative::update_agent(Node2D *agent) {
	if (!agent) return;
	int64_t id = agent->get_instance_id();
	Vector2i cur = _cell(agent->get_global_position());
	Vector2i prev = last_cell.count(id) ? last_cell[id] : cur;
	if (cur == prev) return;

	int64_t prev_key = cell_hash(prev);
	int64_t cur_key = cell_hash(cur);

	if (buckets.count(prev_key)) {
		auto &arr = buckets[prev_key].agents;
		arr.erase(std::remove(arr.begin(), arr.end(), agent), arr.end());
		if (arr.empty()) buckets.erase(prev_key);
	}

	buckets[cur_key].agents.push_back(agent);
	last_cell[id] = cur;
}

void SpatialGridNative::unregister_agent(Node2D *agent) {
	if (!agent) return;
	int64_t id = agent->get_instance_id();
	if (!last_cell.count(id)) return;

	Vector2i c = last_cell[id];
	int64_t key = cell_hash(c);

	if (buckets.count(key)) {
		auto &arr = buckets[key].agents;
		arr.erase(std::remove(arr.begin(), arr.end(), agent), arr.end());
		if (arr.empty()) buckets.erase(key);
	}

	last_cell.erase(id);
}

TypedArray<Node2D> SpatialGridNative::get_neighbors(Vector2 pos, int range_cells) {
	TypedArray<Node2D> result;
	Vector2i base = _cell(pos);

	for (int dx = -range_cells; dx <= range_cells; dx++) {
		for (int dy = -range_cells; dy <= range_cells; dy++) {
			Vector2i c = base + Vector2i(dx, dy);
			int64_t key = cell_hash(c);
			if (!buckets.count(key)) continue;
			for (auto *n : buckets[key].agents) {
				if (n) result.push_back(n);
			}
		}
	}
	return result;
}

void SpatialGridNative::set_cell_size(double s) { cell_size = s; }
double SpatialGridNative::get_cell_size() const { return cell_size; }
