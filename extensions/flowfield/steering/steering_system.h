#pragma once

#include "../core/types.h"
#include "../grid/spatial_grid.h"
#include <unordered_map>
#include <vector>

namespace ffcore
{
    class FlowField;
    class SpatialGrid;
    class AgentManager;

    constexpr double FLOW_WEIGHT = 1.0;
    constexpr double CENTER_PULL = 1.0;
    constexpr double TILE_SIZE = 16.0;

    constexpr double WALL_AVOID_RADIUS = TILE_SIZE * 1.2;
    constexpr double WALL_REPEL_STRENGTH = 8.4;

    constexpr double DIRECT_STEER_RADIUS = TILE_SIZE * 2.5;
    constexpr double MIN_SPEED_FRACTION = 0.25;
    constexpr double CELLGOAL_COOLDOWN_SEC = 1;

    constexpr double TARGET_SLOW_RADIUS = TILE_SIZE * 3;
    constexpr double TARGET_APPROACH_RADIUS = TILE_SIZE * 1.0;
    constexpr double TARGET_OCCUPY_RADIUS = TILE_SIZE * 0.4;

    constexpr double SEPARATION_RADIUS = 18.0;
    constexpr double SEPARATION_STRENGTH = 400.0;
    constexpr int MAX_NEIGHBORS = 16;

    constexpr double LERP_GENERAL = 0.02;

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
