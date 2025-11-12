#pragma once
#include <unordered_map>
#include <vector>
#include "../core/types.h"
#include "../flow/flow_field.h"
#include "../grid/spatial_grid.h"

namespace ffcore
{
    // Constantes de réglage pour la navigation
    constexpr double FLOW_WEIGHT = 1.0; // poids direction globale
    constexpr double CENTER_PULL = 1.0; // stabilisation douce
    constexpr double TILE_SIZE = 16.0;

    constexpr double WALL_AVOID_RADIUS = TILE_SIZE * 1.5;
    constexpr double WALL_REPEL_STRENGTH = 8.4; // 12 × 0.7  → force dominante (murs infranchissables)

    constexpr double DIRECT_STEER_RADIUS = TILE_SIZE * 2.5;
    constexpr double MIN_SPEED_FRACTION = 0.25;
    constexpr double CELLGOAL_COOLDOWN_SEC = 1;

    constexpr double TARGET_SLOW_RADIUS = TILE_SIZE * 2.5;
    constexpr double TARGET_APPROACH_RADIUS = TILE_SIZE * 1.0;
    constexpr double TARGET_OCCUPY_RADIUS = TILE_SIZE * 0.4;

    constexpr double SEPARATION_RADIUS = 20.0;
    constexpr double SEPARATION_STRENGTH = 400.0; // 8 × 50 → forte répulsion inter-agent
    constexpr int MAX_NEIGHBORS = 16;

    struct AgentData
    {
        int id = -1;
        Vec2 position;
        Vec2 velocity;
        double max_speed = 60.0;
        bool active = true;
        FlowField *flow = nullptr;
        bool has_arrived = false; /// arrived au final target
        bool is_first = false;    // est le 1er, droit de penetration de la target cell
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
        void smooth_stop(int id);
        void reactivate_agents_for_field(FlowField *field);

    private:
        std::vector<AgentData> agents;
        std::unordered_map<int, int> id_to_index;
        int next_id = 1;

        FlowField *default_flow = nullptr;
        SpatialGrid *grid = nullptr;
        Vec2 compute_separation_force(const AgentData &agent);
    };

    SteeringSystem *get_global_steering_system();

} // namespace ffcore
