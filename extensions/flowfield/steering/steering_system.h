#pragma once

#include "../core/types.h"
#include "../core/global_config.h"
#include "../grid/spatial_grid.h"
#include "agent.h"
#include <unordered_map>
#include <vector>

namespace ffcore
{
    class FlowField;
    class SpatialGrid;
    class AgentManager;
    class SteeringSystem;

    struct Shockwave
    {
        Vec2 pos;
        double radius = 0.0;
        double time_left_ms = 0.0;
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
        void apply_smash_impulse(int id, const Vec2 &direction, double force, double friction_loss, double delay, bool detach_flow);
        void apply_area_smash(const Vec2 &pos, double radius, const Vec2 &direction, double force, double friction_loss, double falloff, bool detach_flow);
        void apply_explosion(const Vec2 &pos, double radius, double intensity, double friction_loss);
        void set_agent_never_rest(int id, bool value);

    private:
        std::vector<AgentData> agents;
        std::unordered_map<int, int> id_to_index;
        int next_id = 1;
        std::vector<Shockwave> shockwaves;

        FlowField *default_flow = nullptr;
        SpatialGrid *grid = nullptr;

        AgentManager *agent_manager = nullptr;

        Vec2 force_voisine(const AgentData &agent);
        Vec2 wall_repulsion_force(const AgentData &a, FlowField *ff);
        void ultimate_wall_correction(AgentData &a, FlowField *ff, double delta);
        Vec2 apply_walk_with_walls(const Vec2 &from, const Vec2 &step, FlowField *ff);
        bool is_player_footprint_navigable(const Vec2 &bottom_center, FlowField *ff) const;
        Vec2 apply_player_walk_with_walls(const Vec2 &from, const Vec2 &step, FlowField *ff);
    };

    SteeringSystem *get_global_steering_system();

} // namespace ffcore
