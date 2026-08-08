#pragma once

#include "../core/navigation_world.h"
#include "../jobs/flow_field_job_queue.h"
#include "navigation_route_2d.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include <unordered_map>

namespace godot
{
    class NavigationWorld2D : public Node
    {
        GDCLASS(NavigationWorld2D, Node);

    private:
        ffcore::NavigationWorld world;
        ffcore::FlowFieldJobQueue jobs;
        ffcore::FlowHandle latest_flow_handle;
        struct PendingFlow
        {
            ffcore::FlowHandle handle;
            bool publish_as_latest = false;
        };
        std::unordered_map<std::uint64_t, PendingFlow> flow_by_request;

        static std::int64_t encode_area_handle(ffcore::AreaHandle handle);
        static std::int64_t encode_portal_handle(ffcore::PortalHandle handle);
        static std::int64_t encode_flow_handle(ffcore::FlowHandle handle);
        static ffcore::AreaHandle decode_area_handle(std::int64_t encoded);
        static ffcore::PortalHandle decode_portal_handle(std::int64_t encoded);
        static ffcore::FlowHandle decode_flow_handle(std::int64_t encoded);
        std::uint64_t submit_flow_request(Vector2i goal, bool publish_as_latest,
                                          const ffcore::FlowBuildOptions &options,
                                          ffcore::FlowHandle &flow_handle);
        static ffcore::FlowBuildOptions make_flow_options(
            std::int64_t blocker_channel_mask, int directional_channel);
        static std::vector<ffcore::Vec2i> convert_cells(
            const PackedVector2Array &cells);

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
        PackedVector2Array find_path_cells_with_options(
            Vector2i start, Vector2i goal, std::int64_t blocker_channel_mask) const;
        bool replace_blocker_channel(int channel, const PackedVector2Array &cells,
                                     bool blocks_navigation, bool blocks_physics);
        bool clear_blocker_channel(int channel);
        bool set_blocker_channel_cell(int channel, Vector2i cell, bool blocked,
                                      bool blocks_navigation, bool blocks_physics);
        bool replace_directional_traversal_channel(
            int channel, const PackedVector2Array &cells,
            const PackedVector2Array &directions);
        bool clear_directional_traversal_channel(int channel);
        bool build_flow_to_cell(Vector2i goal);
        std::int64_t create_flow_to_cell(Vector2i goal);
        std::int64_t create_flow_to_cell_with_options(
            Vector2i goal, std::int64_t blocker_channel_mask, int directional_channel);
        std::int64_t request_flow_to_cell(Vector2i goal);
        std::int64_t request_flow_handle_to_cell(Vector2i goal);
        std::int64_t request_flow_handle_to_cell_with_options(
            Vector2i goal, std::int64_t blocker_channel_mask, int directional_channel);
        void cancel_flow_request(std::int64_t request_id);
        bool cancel_flow(std::int64_t flow_handle);
        bool release_flow(std::int64_t flow_handle);
        int get_flow_status(std::int64_t flow_handle) const;
        Vector2 sample_flow(std::int64_t flow_handle, Vector2 world_position) const;
        double get_flow_route_cost(std::int64_t flow_handle, Vector2 world_position) const;
        Dictionary get_flow_diagnostics(std::int64_t flow_handle) const;
        Array get_flow_bottlenecks(std::int64_t flow_handle) const;
        PackedInt64Array get_flow_handles() const;
        Vector2 sample_latest_flow(Vector2 world_position) const;
        std::int64_t get_topology_revision() const;
        std::int64_t get_cost_revision() const;

        std::int64_t create_area(const PackedVector2Array &interior_cells,
                                 const PackedVector2Array &target_cells);
        std::int64_t create_garden(const PackedVector2Array &interior_cells,
                                   const PackedVector2Array &target_cells);
        std::int64_t create_garden_from_seed(
            Vector2i seed, int maximum_cells, std::int64_t blocker_channel_mask);
        std::int64_t create_portal(std::int64_t area_handle,
                                   const PackedVector2Array &boundary_cells,
                                   const PackedVector2Array &outside_cells,
                                   int direction,
                                   int capacity);
        std::int64_t create_garden_portal(
            std::int64_t garden_handle,
            const PackedVector2Array &boundary_cells,
            const PackedVector2Array &outside_cells,
            int direction,
            int capacity);
        bool remove_area(std::int64_t area_handle);
        bool remove_garden(std::int64_t garden_handle);
        bool set_garden_cells(std::int64_t garden_handle,
                              const PackedVector2Array &interior_cells);
        bool set_garden_target_cells(std::int64_t garden_handle,
                                     const PackedVector2Array &target_cells);
        bool remove_portal(std::int64_t portal_handle);
        Dictionary get_garden_info(std::int64_t garden_handle) const;
        Dictionary get_portal_info(std::int64_t portal_handle) const;
        PackedInt64Array get_garden_handles() const;
        PackedInt64Array get_portal_handles() const;
        Ref<NavigationRoute2D> plan_enter_area(std::int64_t area_handle,
                                               Vector2i world_start,
                                               Vector2i area_destination) const;
        Ref<NavigationRoute2D> plan_exit_area(std::int64_t area_handle,
                                              Vector2i area_start,
                                              Vector2i world_destination) const;
        Ref<NavigationRoute2D> plan_enter_garden(
            std::int64_t garden_handle, Vector2i world_start,
            Vector2i garden_destination, std::int64_t blocker_channel_mask) const;
        Ref<NavigationRoute2D> plan_exit_garden(
            std::int64_t garden_handle, Vector2i garden_start,
            Vector2i world_destination, std::int64_t blocker_channel_mask) const;
        bool is_route_current(const Ref<NavigationRoute2D> &route) const;

        bool copy_latest_flow(ffcore::FlowField &destination) const;
        bool copy_flow(ffcore::FlowHandle handle, ffcore::FlowField &destination) const;
        const ffcore::GridDefinition &grid_definition() const { return world.grid(); }
    };
} // namespace godot
