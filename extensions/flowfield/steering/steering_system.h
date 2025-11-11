#pragma once
#include <unordered_map>
#include <vector>
#include "../core/types.h"
#include "../flow/flow_field.h"
#include "../grid/spatial_grid.h"

namespace ffcore
{
    // Constantes de réglage pour la navigation
    constexpr double FLOW_WEIGHT = 1.0;

    constexpr double CENTER_PULL = 0.25;
    constexpr double TILE_SIZE = 16.0;
    constexpr double WALL_AVOID_RADIUS = TILE_SIZE * 1.5;
    constexpr double WALL_REPEL_STRENGTH = 0.7;
    constexpr double DIRECT_STEER_RADIUS = TILE_SIZE * 2.5;
    constexpr double MIN_SPEED_FRACTION = 0.25;
    constexpr double CELLGOAL_COOLDOWN_SEC = 1;
    constexpr double TARGET_SLOW_RADIUS = TILE_SIZE * 2.5; // 40.0 si TILE_SIZE = 16
    constexpr double TARGET_APPROACH_RADIUS = TILE_SIZE * 1.0;
    constexpr double TARGET_OCCUPY_RADIUS = TILE_SIZE * 0.4;

    struct AgentData
    {
        int id = -1;
        Vec2 position;
        Vec2 velocity;
        double max_speed = 60.0;
        bool active = true;
        FlowField *flow = nullptr;
        bool has_arrived = false;
    };

    class SteeringSystem
    {
    public:
        SteeringSystem();

        int register_agent(const Vec2 &pos, double max_speed, FlowField *flow);
        void unregister_agent(int id);

        void set_default_flowfield(FlowField *f);
        void set_grid(SpatialGrid *g);

        void update_all(double delta);

        const AgentData *get_agent(int id) const;
        void soft_wall_correction(AgentData &a, FlowField *ff, double delta);
        void smooth_stop(int id, double rate = 0.25);

    private:
        std::vector<AgentData> agents;
        std::unordered_map<int, int> id_to_index;
        int next_id = 1;

        FlowField *default_flow = nullptr;
        SpatialGrid *grid = nullptr;
        Vec2 compute_separation_force(const AgentData &agent, double dist_to_target, bool in_goal_tile);
    };

} // namespace ffcore
