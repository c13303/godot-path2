#pragma once

#include "../core/types.h"
#include "../core/global_config.h"
#include "../grid/spatial_grid.h"
#include <unordered_map>
#include <vector>

namespace ffcore
{
    class FlowField;
    class SpatialGrid;
    class AgentManager;

    struct AgentData
    {
        int id = -1;
        Vec2 position;
        Vec2 velocity;
        double max_speed = 60.0;
        bool active = true;

        FlowField *flow = nullptr;

        bool has_arrived = false;
        bool is_first = false;
        GroupID group = INVALID_GROUP;
        Vec2 smash_force{};
        bool is_propelled = false;
        double propelled_timer = 0.0;
        bool smash_just_reset = false;
        double smash_friction = -1.0; // perte de vitesse par seconde (0..1), -1 => fallback global
        Vec2 pending_smash{};
        double smash_delay = 0.0;
        double pending_smash_friction = -1.0;
        bool smash_pending = false;
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
        void apply_explosion(const Vec2 &pos, double radius, double intensity, double friction_loss);

    private:
        std::vector<AgentData> agents;
        std::unordered_map<int, int> id_to_index;
        int next_id = 1;

        FlowField *default_flow = nullptr;
        SpatialGrid *grid = nullptr;

        AgentManager *agent_manager = nullptr;

        Vec2 force_voisine(const AgentData &agent);
        Vec2 wall_repulsion_force(const AgentData &a, FlowField *ff);
        void ultimate_wall_correction(AgentData &a, FlowField *ff, double delta);
    };

    SteeringSystem *get_global_steering_system();

} // namespace ffcore
