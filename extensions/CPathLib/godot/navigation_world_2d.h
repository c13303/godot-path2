#pragma once

#include "../core/navigation_world.h"
#include "../jobs/flow_field_job_queue.h"
#include "navigation_route_2d.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

namespace godot
{
    class NavigationWorld2D : public Node
    {
        GDCLASS(NavigationWorld2D, Node);

    private:
        ffcore::NavigationWorld world;
        ffcore::FlowFieldJobQueue jobs;
        ffcore::FlowField latest_flow;
        bool has_latest_flow = false;

        static std::int64_t encode_area_handle(ffcore::AreaHandle handle);
        static std::int64_t encode_portal_handle(ffcore::PortalHandle handle);
        static ffcore::AreaHandle decode_area_handle(std::int64_t encoded);

    protected:
        static void _bind_methods();

    public:
        void _process(double delta) override;

        bool configure_grid(Rect2i bounds,
                            double cell_size,
                            Vector2 world_origin,
                            const PackedVector2Array &walkable_cells,
                            const PackedVector2Array &physical_wall_cells);
        bool configure_sparse_grid(const PackedVector2Array &walkable_cells,
                                   const PackedVector2Array &blocked_cells);
        void configure_flow(double wall_clearance_weight,
                            bool detect_bottlenecks,
                            int bottleneck_zone_radius);
        bool set_cell_walkable(Vector2i cell, bool walkable);
        bool set_cell_physics_blocked(Vector2i cell, bool blocked);
        bool set_cell_traversal_cost(Vector2i cell, double cost);
        PackedVector2Array find_path_cells(Vector2i start, Vector2i goal) const;
        bool build_flow_to_cell(Vector2i goal);
        std::int64_t request_flow_to_cell(Vector2i goal);
        void cancel_flow_request(std::int64_t request_id);
        Vector2 sample_latest_flow(Vector2 world_position) const;
        std::int64_t get_topology_revision() const;
        std::int64_t get_cost_revision() const;

        std::int64_t create_area(const PackedVector2Array &interior_cells,
                                 const PackedVector2Array &target_cells);
        std::int64_t create_portal(std::int64_t area_handle,
                                   const PackedVector2Array &boundary_cells,
                                   const PackedVector2Array &outside_cells,
                                   int direction,
                                   int capacity);
        bool remove_area(std::int64_t area_handle);
        Ref<NavigationRoute2D> plan_enter_area(std::int64_t area_handle,
                                               Vector2i world_start,
                                               Vector2i area_destination) const;
        Ref<NavigationRoute2D> plan_exit_area(std::int64_t area_handle,
                                              Vector2i area_start,
                                              Vector2i world_destination) const;
        bool is_route_current(const Ref<NavigationRoute2D> &route) const;

        bool copy_latest_flow(ffcore::FlowField &destination) const;
    };
} // namespace godot
