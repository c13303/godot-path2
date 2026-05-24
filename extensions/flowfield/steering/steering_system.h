#pragma once

#include "../core/types.h"
#include "../core/global_config.h"
#include "../grid/spatial_grid.h"
#include "agent.h"
#include <unordered_map>
#include <unordered_set>
#include <vector>

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
        int affected_smash_classes = 0;
        double time_left = 0.0;
        std::unordered_set<int> hit_ids;
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
        void spawn_aoe_zone(const Vec2 &pos, const Vec2 &direction, double radius, double angle_degrees, double duration, double force, double friction_loss, double falloff, bool detach_flow, double control_suppression, double control_suppression_duration, int ignored_agent_id, int affected_smash_classes);
        void set_agent_never_rest(int id, bool value);
        double get_max_fight_query_padding() const { return max_fight_query_padding; }

    private:
        std::vector<AgentData> agents;
        std::unordered_map<int, int> id_to_index;
        int next_id = 1;
        std::vector<ActiveAoE> active_aoes;
        double max_fight_query_padding = 0.0;
        double max_world_radius = 0.0;

        FlowField *default_flow = nullptr;
        SpatialGrid *grid = nullptr;

        AgentManager *agent_manager = nullptr;

        Vec2 force_voisine(const AgentData &agent);
        Vec2 wall_repulsion_force(const AgentData &a, FlowField *ff);
        void ultimate_wall_correction(AgentData &a, FlowField *ff, double delta);
        Vec2 apply_walk_with_walls(const AgentData &agent, const Vec2 &step, FlowField *ff);
        bool is_agent_footprint_navigable(const Vec2 &body_position, const AgentProfile &profile, FlowField *ff) const;
        AgentProfile sanitize_agent_profile(const AgentProfile &profile) const;
        void recompute_hitbox_query_extents();
    };

    SteeringSystem *get_global_steering_system();

} // namespace ffcore
