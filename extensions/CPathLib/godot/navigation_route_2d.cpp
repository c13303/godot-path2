#include "navigation_route_2d.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot
{
    void NavigationRoute2D::_bind_methods()
    {
        ClassDB::bind_method(D_METHOD("get_status"), &NavigationRoute2D::get_status);
        ClassDB::bind_method(D_METHOD("get_segment_count"), &NavigationRoute2D::get_segment_count);
        ClassDB::bind_method(D_METHOD("get_segment_type", "segment_index"), &NavigationRoute2D::get_segment_type);
        ClassDB::bind_method(D_METHOD("get_segment_cells", "segment_index"), &NavigationRoute2D::get_segment_cells);
        ClassDB::bind_method(D_METHOD("get_topology_revision"), &NavigationRoute2D::get_topology_revision);
        ClassDB::bind_method(D_METHOD("get_area_revision"), &NavigationRoute2D::get_area_revision);
    }

    int NavigationRoute2D::get_status() const
    {
        return static_cast<int>(route.status);
    }

    int NavigationRoute2D::get_segment_count() const
    {
        return static_cast<int>(route.segments.size());
    }

    int NavigationRoute2D::get_segment_type(int segment_index) const
    {
        if (segment_index < 0 || segment_index >= static_cast<int>(route.segments.size()))
            return -1;
        return static_cast<int>(route.segments[segment_index].type);
    }

    PackedVector2Array NavigationRoute2D::get_segment_cells(int segment_index) const
    {
        PackedVector2Array result;
        if (segment_index < 0 || segment_index >= static_cast<int>(route.segments.size()))
            return result;
        const std::vector<ffcore::Vec2i> &cells = route.segments[segment_index].cells;
        result.resize(static_cast<int>(cells.size()));
        for (int index = 0; index < static_cast<int>(cells.size()); ++index)
            result.set(index, Vector2(cells[index].x, cells[index].y));
        return result;
    }

    std::int64_t NavigationRoute2D::get_topology_revision() const
    {
        return static_cast<std::int64_t>(route.topology_revision);
    }

    std::int64_t NavigationRoute2D::get_area_revision() const
    {
        return static_cast<std::int64_t>(route.area_revision);
    }
} // namespace godot
