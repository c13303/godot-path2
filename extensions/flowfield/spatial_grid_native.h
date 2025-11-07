#ifndef SPATIAL_GRID_NATIVE_H
#define SPATIAL_GRID_NATIVE_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <unordered_map>
#include <vector>

namespace godot {

struct GridBucket {
	std::vector<Node2D*> agents;
};

class SpatialGridNative : public Node {
	GDCLASS(SpatialGridNative, Node)

protected:
	static void _bind_methods();

public:
	SpatialGridNative();
	~SpatialGridNative();

	void clear();
	void register_agent(Node2D* agent);
	void update_agent(Node2D* agent);
	void unregister_agent(Node2D* agent);
	TypedArray<Node2D> get_neighbors(Vector2 pos, int range_cells = 1);

	void set_cell_size(double s);
	double get_cell_size() const;

private:
	Vector2i _cell(const Vector2& p) const;

private:
	std::unordered_map<int64_t, GridBucket> buckets;
	std::unordered_map<int64_t, Vector2i> last_cell;
	double cell_size = 32.0;
};

}

#endif
