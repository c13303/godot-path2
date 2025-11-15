#ifndef SPATIAL_GRID_NATIVE_H
#define SPATIAL_GRID_NATIVE_H

#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include "../grid/spatial_grid.h"

namespace godot
{

    class SpatialGridNative : public Node2D
    {
        GDCLASS(SpatialGridNative, Node2D);
        ffcore::SpatialGrid grid;

    public:
        ffcore::SpatialGrid *get_grid() { return &grid; }
        static void _bind_methods() {}
    };

}

#endif
