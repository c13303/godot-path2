#pragma once
#include <unordered_map>
#include <vector>
#include "../core/types.h"
#include "../flow/flow_field.h"
#include "../grid/spatial_grid.h"

namespace ffcore
{

    struct AgentData
    {
        int id = -1;
        Vec2 position;
        Vec2 velocity;
        double max_speed = 60.0;
        bool active = true;
        FlowField *flow = nullptr;
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

    private:
        std::vector<AgentData> agents;
        std::unordered_map<int, int> id_to_index;
        int next_id = 1;

        FlowField *default_flow = nullptr;
        SpatialGrid *grid = nullptr;
    };

} // namespace ffcore
