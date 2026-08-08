#pragma once

#include "agent_world.h"
#include "impulse_system.h"
#include "steering_solver.h"
#include "../steering/terrain_speed_grid.h"
#include "../bottleneck/bottleneck_traffic_controller.h"

namespace ffcore
{
    class CrowdWorld
    {
    private:
        AgentWorld agents;
        SpatialGrid spatial;
        TerrainSpeedGrid terrain_speeds;
        ImpulseSystem impulses;
        BottleneckTrafficController traffic;
        FlowField shared_flow;
        bool has_shared_flow = false;

        static Vec2 approach(const Vec2 &current, const Vec2 &target, double maximum_change);
        Vec2 resolve_motion(const CrowdAgentState &agent, const Vec2 &candidate) const;

    public:
        explicit CrowdWorld(double spatial_cell_size = 32.0) : spatial(spatial_cell_size) {}

        AgentHandle add_agent(const Vec2 &position, const CrowdAgentProfile &profile = {});
        bool remove_agent(AgentHandle handle);
        CrowdAgentState *get_agent(AgentHandle handle) { return agents.get(handle); }
        const CrowdAgentState *get_agent(AgentHandle handle) const { return agents.get(handle); }
        std::vector<AgentHandle> active_agents() const { return agents.active_handles(); }

        void set_shared_flow(const FlowField &flow);
        void clear_shared_flow();
        bool follow_flow(AgentHandle handle);
        bool follow_path(AgentHandle handle, const std::vector<Vec2> &world_points);
        bool set_manual_direction(AgentHandle handle, const Vec2 &direction);
        bool stop_navigation(AgentHandle handle);
        bool set_paused(AgentHandle handle, bool paused);

        void apply_impulse(AgentHandle handle, const ImpulseRequest &request);
        bool refresh_external_velocity(AgentHandle handle, int source_id, const Vec2 &velocity,
                                       double response_seconds, double expiry_seconds);
        bool release_external_velocity(AgentHandle handle, int source_id);
        void configure_bottleneck(std::uint64_t bottleneck_id,
                                  const BottleneckTrafficConfig &config);
        bool request_bottleneck(std::uint64_t bottleneck_id, AgentHandle handle,
                                TrafficDirection direction, int priority = 0);
        bool has_bottleneck_access(std::uint64_t bottleneck_id, AgentHandle handle) const;
        void release_bottleneck(std::uint64_t bottleneck_id, AgentHandle handle);

        TerrainSpeedGrid &terrain_speed_grid() { return terrain_speeds; }
        const TerrainSpeedGrid &terrain_speed_grid() const { return terrain_speeds; }
        void update(double delta);
        std::size_t size() const { return agents.size(); }
    };
} // namespace ffcore
