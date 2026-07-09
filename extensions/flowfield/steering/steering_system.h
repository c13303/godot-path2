#pragma once

#include "../core/types.h"
#include "../core/global_config.h"
#include "../grid/spatial_grid.h"
#include "agent.h"
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <cmath>
#include <algorithm>

namespace ffcore
{
    class FlowField;
    class SpatialGrid;
    class AgentManager;
    class SteeringSystem;

    struct ActiveAoE
    {
        Vec2 pos;
        Vec2 direction;        // ignored when angle_degrees >= 360 (radial)
        double radius = 0.0;
        double angle_degrees = 360.0;
        double force = 0.0;
        double friction_loss = 0.0;
        double falloff = 0.0;
        bool detach_flow = false;
        double control_suppression = 1.0;
        double control_suppression_duration = 0.0;
        int ignored_agent_id = -1;
        int owner_id = -1; // if valid, zone.pos tracks this agent's live position each tick
        Vec2 follow_offset; // added to the owner's live position so the zone can sit off-center
        int affected_smash_classes = 0;
        int damage = 0;
        double time_left = 0.0;
        int continuous_id = -1;
        double damage_frequency = 0.0;
        double repulse_frequency = 0.0;
        std::unordered_set<int> hit_ids;
        std::unordered_map<int, double> damage_cooldowns;
        std::unordered_map<int, double> repulse_cooldowns;
    };

    struct DamageEvent
    {
        int agent_id = -1;
        int damage = 0;
        Vec2 position;
    };

    struct BottleneckReservation
    {
        int owner_id = -1;
        double time_left = 0.0;
    };

    // Generic static circular obstacle. The C++ core knows nothing about what it
    // represents game-side (turret, prop, ...): it is only a position + radius that
    // moving agents are repelled from. Never registered as an agent, never updated
    // per tick, never iterated by AoE/fight/flowfield systems.
    struct StaticObstacle
    {
        int id = -1;
        Vec2 position;
        double radius = 0.0;
        double push_strength = 1.0;
    };

    struct DirectionalCellFieldSample
    {
        bool phase_bound = false;
        bool field_found = false;
        bool exact = false;
        bool fallback = false;
        int field_id = -1;
        Vec2 sample_world;
        Vec2i sample_cell;
        Vec2 velocity;
    };

    class SteeringSystem
    {
    public:
        SteeringSystem();

        int register_agent(const Vec2 &pos, double max_speed, FlowField *flow);
        void unregister_agent(int id);

        void set_grid(SpatialGrid *g);
        void set_default_flowfield(FlowField *f);

        void set_agent_manager(AgentManager *m) { agent_manager = m; }

        const AgentData *get_agent(int id) const;
        void reactivate_agents_for_field(FlowField *field);

        void smooth_stop(int id);
        void update_all(double delta);
        void set_agent_group(int id, GroupID group);
        int register_agent_with_id(int fixed_id, const Vec2 &pos, double max_speed, FlowField *flow);
        void set_agent_flow_ptr(int id, FlowField *ff);
        void set_agent_control_mode(int id, int mode);
        void set_agent_input(int id, const Vec2 &direction);
        void set_agent_manual_motion(int id, double acceleration, double deceleration);
        void set_agent_profile(int id, const AgentProfile &profile);
        void apply_smash_impulse(int id, const Vec2 &direction, double force, double friction_loss, double delay, bool detach_flow, double control_suppression, double control_suppression_duration);
        void apply_area_smash(const Vec2 &pos, double radius, const Vec2 &direction, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes);
        void apply_cone_smash(const Vec2 &pos, double radius, const Vec2 &direction, double angle_degrees, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes);
        void apply_explosion(const Vec2 &pos, double radius, double intensity, double friction_loss);
        void apply_explosion_filtered(const Vec2 &pos, double radius, double intensity, double friction_loss, double falloff, int ignored_agent_id, double control_suppression, double control_suppression_duration, int affected_smash_classes);
        void spawn_aoe_zone(const Vec2 &pos, const Vec2 &direction, double radius, double angle_degrees, double duration, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes, const Vec2 &follow_offset, int damage);
        int start_continuous_aoe(const Vec2 &pos, const Vec2 &direction, double radius, double angle_degrees, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes, const Vec2 &follow_offset, int damage, double damage_frequency, double repulse_frequency);
        bool update_continuous_aoe(int continuous_id, const Vec2 &direction, const Vec2 &follow_offset);
        void stop_continuous_aoe(int continuous_id);
        void apply_area_damage(const Vec2 &pos, double radius, int ignored_agent_id, int affected_smash_classes, int damage);
        std::vector<DamageEvent> take_damage_events();
        void set_agent_never_rest(int id, bool value);
        void set_agent_paused(int id, bool value);
        // Lazy flow fields: stamp the group whose flow field this (not-yet-attached) agent
        // is waiting on, so it freezes and shows "ff wait"/"ff being computed" until ready.
        // INVALID_GROUP clears it. See AgentData::waiting_flow_group.
        void set_agent_waiting_flow_group(int id, GroupID group);
        void set_agent_phase(int id, AgentPhase phase, float eating_seconds);
        double get_max_fight_query_padding() const { return max_fight_query_padding; }

        // Path-follow API. Agent keeps its flow pointer (for wall-repel / bottleneck
        // physics), but desired direction is sourced from the path while one is active.
        void set_agent_path(int id, const std::vector<Vec2> &waypoints_world);
        void clear_agent_path(int id);
        bool agent_path_arrived(int id) const;

        // Generic static circular obstacle registry. Game-side decides which world
        // positions become obstacles; the core only stores/queries them so moving
        // agents are locally pushed around them. These are NOT agents.
        void register_static_obstacle(int id, const Vec2 &position, double radius, double push_strength = 1.0);
        void unregister_static_obstacle(int id);
        void clear_static_obstacles();
        bool has_static_obstacle(int id) const;
        int get_static_obstacle_count() const { return (int)static_obstacles.size(); }

        // Generic sparse per-cell direction fields. Game-side owns the semantic
        // meaning (water current, conveyor, wind, etc.); the core only samples a
        // world position into a cell and returns a velocity target for bound phases.
        void set_directional_cell_field(int field_id, const Vec2 &origin_world, double tile_size, double speed, const std::vector<Vec2i> &cells, const std::vector<Vec2> &directions, const Vec2 &sample_offset_world = Vec2(0, 0), double sample_radius_world = 0.0);
        void clear_directional_cell_field(int field_id);
        void clear_directional_cell_fields();
        void bind_phase_directional_cell_field(AgentPhase phase, int field_id);
        void clear_phase_directional_cell_field(AgentPhase phase);
        DirectionalCellFieldSample directional_cell_field_sample_for_agent(const AgentData &agent) const;

    private:
        // Dedicated spatial index for static obstacles. Kept separate from the moving-agent
        // SpatialGrid so obstacle ids can never leak into id_to_index / agent iteration.
        struct StaticObstacleGrid
        {
            double cell_size = 32.0;
            std::unordered_map<long long, std::vector<int>> cells;
            std::unordered_map<int, long long> id_cell;

            long long key(int cx, int cy) const
            {
                return (static_cast<long long>(cx) << 32) ^ static_cast<unsigned int>(cy);
            }
            long long key_for(const Vec2 &p) const
            {
                int cx = (int)std::floor(p.x / cell_size);
                int cy = (int)std::floor(p.y / cell_size);
                return key(cx, cy);
            }
            void insert(int id, const Vec2 &p)
            {
                long long k = key_for(p);
                cells[k].push_back(id);
                id_cell[id] = k;
            }
            void remove(int id)
            {
                auto it = id_cell.find(id);
                if (it == id_cell.end())
                    return;
                auto cell_it = cells.find(it->second);
                if (cell_it != cells.end())
                {
                    auto &list = cell_it->second;
                    list.erase(std::remove(list.begin(), list.end(), id), list.end());
                    if (list.empty())
                        cells.erase(cell_it);
                }
                id_cell.erase(it);
            }
            void clear()
            {
                cells.clear();
                id_cell.clear();
            }
            void query(const Vec2 &p, double radius, std::vector<int> &out) const
            {
                out.clear();
                if (cells.empty())
                    return;
                int r = (int)std::ceil(radius / cell_size);
                int cx = (int)std::floor(p.x / cell_size);
                int cy = (int)std::floor(p.y / cell_size);
                for (int dy = -r; dy <= r; ++dy)
                    for (int dx = -r; dx <= r; ++dx)
                    {
                        auto it = cells.find(key(cx + dx, cy + dy));
                        if (it == cells.end())
                            continue;
                        for (int id : it->second)
                            out.push_back(id);
                    }
            }
        };

        struct DirectionalCellField
        {
            Vec2 origin_world;
            Vec2 sample_offset_world;
            double tile_size = 32.0;
            double speed = 0.0;
            double sample_radius_world = 0.0;
            std::unordered_map<long long, Vec2> directions;

            long long key(int x, int y) const
            {
                return (static_cast<long long>(x) << 32) ^ static_cast<unsigned int>(y);
            }
            Vec2i world_to_cell(const Vec2 &world) const
            {
                const double safe_tile = std::max(1.0, tile_size);
                return Vec2i(
                    (int)std::floor((world.x - origin_world.x) / safe_tile),
                    (int)std::floor((world.y - origin_world.y) / safe_tile));
            }
        };

        std::vector<AgentData> agents;
        std::unordered_map<int, int> id_to_index;
        int next_id = 1;
        int next_continuous_aoe_id = 1;
        std::vector<ActiveAoE> active_aoes;
        std::vector<DamageEvent> damage_events;
        std::unordered_map<int, std::unordered_map<int, double>> contact_push_cooldowns;
        std::unordered_map<FlowField *, std::unordered_map<int, BottleneckReservation>> bottleneck_reservations;
        std::unordered_map<FlowField *, std::unordered_map<int, int>> bottleneck_core_occupancy;
        double max_fight_query_padding = 0.0;
        double max_world_radius = 0.0;

        // Phase-1 diagnostic: worst-case neighbor list size returned by
        // query_neighbors() during the current update_all() frame. Reset at the top
        // of update_all(), sampled in force_voisine(). A value far above realistic
        // local crowding is the direct cost driver and points at a grid ID leak.
        size_t debug_max_neighbor_query_size = 0;

        // Static obstacle storage. Touched only on register/unregister/clear, never per tick.
        std::unordered_map<int, StaticObstacle> static_obstacles;
        StaticObstacleGrid static_obstacle_grid;
        double max_static_obstacle_radius = 0.0;

        std::unordered_map<int, DirectionalCellField> directional_cell_fields;
        std::unordered_map<int, int> phase_directional_cell_fields;

        FlowField *default_flow = nullptr;
        SpatialGrid *grid = nullptr;

        AgentManager *agent_manager = nullptr;

        double movement_priority(const AgentData &agent) const;
        void update_contact_push_cooldowns(double delta);
        void apply_contact_pushes(double delta);
        void queue_smash_impulse(int id, const Vec2 &direction, double force, double friction_loss, double delay, bool detach_flow, double control_suppression, double control_suppression_duration, bool respect_weapon_immune);
        Vec2 force_voisine(const AgentData &agent);
        // Soft static obstacle repulsion (pushes agents away from circular obstacles).
        Vec2 static_obstacle_repulsion_force(const AgentData &agent);
        Vec2 directional_cell_field_velocity_for_agent(const AgentData &agent) const;
        // Hard depenetration: pushes an agent's foot point out of any overlapping static
        // obstacle after integration. Guarantees blocking even when soft steering is
        // damped by lerp/momentum. Generic: applies to any moving agent.
        void resolve_static_obstacle_overlap(AgentData &agent);
        Vec2 wall_repulsion_force(const AgentData &a, FlowField *ff);
        void apply_bottleneck_traffic(AgentData &agent, FlowField *ff, Vec2 &target_velocity, double delta);
        Vec2 desired_velocity_for_flow(const AgentData &agent, FlowField *ff, const Vec2 &nav_dir, const Vec2 &wall_repel, const Vec2 &agent_separation, const Vec2 &static_obstacle_repel, double target_speed) const;
        void ultimate_wall_correction(AgentData &a, FlowField *ff, double delta);
        Vec2 apply_walk_with_walls(const AgentData &agent, const Vec2 &step, FlowField *ff);
        bool is_agent_footprint_navigable(const Vec2 &body_position, const AgentProfile &profile, FlowField *ff) const;
        AgentProfile sanitize_agent_profile(const AgentProfile &profile) const;
        void recompute_hitbox_query_extents();
    };

    SteeringSystem *get_global_steering_system();

} // namespace ffcore
