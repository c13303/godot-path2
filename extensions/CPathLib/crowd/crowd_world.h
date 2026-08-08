#pragma once

#include "agent_world.h"
#include "cohort_store.h"
#include "crowd_profile_store.h"
#include "impulse_system.h"
#include "steering_solver.h"
#include "../steering/terrain_speed_grid.h"
#include "../bottleneck/bottleneck_traffic_controller.h"

#include <cstdint>
#include <unordered_map>

namespace ffcore
{
    struct CrowdWorldConfig
    {
        CrowdAgentProfile default_agent_profile;
        bool paused = false;
    };

    class CrowdWorld
    {
    private:
        AgentWorld agents;
        SpatialGrid spatial;
        TerrainSpeedGrid terrain_speeds;
        ImpulseSystem impulses;
        BottleneckTrafficController traffic;
        CrowdProfileStore profiles;
        CohortStore cohorts;
        CrowdWorldConfig config;
        std::unordered_map<std::uint64_t, FlowField> installed_flows;
        FlowHandle default_flow_handle;

        static Vec2 approach(const Vec2 &current, const Vec2 &target, double maximum_change);
        static std::uint64_t key(AgentHandle handle);
        static std::uint64_t key(FlowHandle handle);
        const FlowField *flow_for(const CrowdAgentState &agent) const;
        Vec2 resolve_motion(const CrowdAgentState &agent, const Vec2 &candidate,
                            const FlowField *flow) const;

    public:
        explicit CrowdWorld(double spatial_cell_size = 32.0) : spatial(spatial_cell_size) {}

        void set_config(const CrowdWorldConfig &new_config);
        const CrowdWorldConfig &get_config() const { return config; }

        ProfileHandle create_profile(const CrowdAgentProfile &profile);
        bool update_profile(ProfileHandle handle, const CrowdAgentProfile &profile);
        bool remove_profile(ProfileHandle handle);
        const CrowdAgentProfile *get_profile(ProfileHandle handle) const;

        AgentHandle add_agent(const Vec2 &position);
        AgentHandle add_agent(const Vec2 &position, const CrowdAgentProfile &profile);
        AgentHandle add_agent(const Vec2 &position, ProfileHandle profile);
        bool remove_agent(AgentHandle handle);
        CrowdAgentState *get_agent(AgentHandle handle) { return agents.get(handle); }
        const CrowdAgentState *get_agent(AgentHandle handle) const { return agents.get(handle); }
        std::vector<AgentHandle> active_agents() const { return agents.active_handles(); }

        bool set_agent_profile(AgentHandle agent, ProfileHandle profile);

        CohortHandle create_cohort();
        bool remove_cohort(CohortHandle handle);
        bool assign_agent_to_cohort(AgentHandle agent, CohortHandle cohort);
        bool remove_agent_from_cohort(AgentHandle agent);
        bool assign_cohort_flow(CohortHandle cohort, FlowHandle flow);
        std::size_t cohort_member_count(CohortHandle cohort) const;

        bool install_flow(FlowHandle handle, const FlowField &flow);
        bool remove_flow(FlowHandle handle);
        void set_shared_flow(const FlowField &flow);
        void clear_shared_flow();
        bool follow_flow(AgentHandle handle);
        bool follow_flow(AgentHandle handle, FlowHandle flow);
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
        std::size_t profile_count() const { return profiles.size(); }
        std::size_t cohort_count() const { return cohorts.size(); }
        std::size_t installed_flow_count() const { return installed_flows.size(); }
    };
} // namespace ffcore
