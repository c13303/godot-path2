#pragma once

#include "../area/route_planner.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

namespace godot
{
    class NavigationRoute2D : public RefCounted
    {
        GDCLASS(NavigationRoute2D, RefCounted);

    private:
        ffcore::RoutePlan route;

    protected:
        static void _bind_methods();

    public:
        void set_core_route(const ffcore::RoutePlan &value) { route = value; }
        const ffcore::RoutePlan &core_route() const { return route; }

        int get_status() const;
        int get_segment_count() const;
        int get_segment_type(int segment_index) const;
        PackedVector2Array get_segment_cells(int segment_index) const;
        std::int64_t get_topology_revision() const;
        std::int64_t get_area_revision() const;
    };
} // namespace godot
