#pragma once

#include "agent_world.h"
#include "cohort_store.h"
#include "crowd_profile_store.h"
#include "impulse_system.h"
#include "effect_volume_system.h"
#include "crowd_interaction_system.h"
#include "steering_solver.h"
#include "../steering/terrain_speed_grid.h"
#include "../steering/directional_motion_field_store.h"
#include "../steering/static_obstacle_store.h"
#include "../steering/external_velocity_source_store.h"
#include "../bottleneck/bottleneck_traffic_controller.h"

#include <cstdint>
#include <unordered_map>

namespace ffcore
{
    struct CrowdWorldConfig
    {
        CrowdAgentProfile default_agent_profile;
        CrowdInteractionConfig interactions;
        double static_obstacle_query_padding = 0.0;
        double static_obstacle_repulsion_strength = 1.0;
        bool paused = false;
    };

    class CrowdWorld
    {
    private:
        AgentWorld agents;
        SpatialGrid spatial;
        TerrainSpeedGrid terrain_speeds;
        DirectionalMotionFieldStore directional_fields;
        StaticObstacleStore static_obstacles;
        ExternalVelocitySourceStore external_velocity_sources;
        ImpulseSystem impulses;
        EffectVolumeSystem effect_volumes;
        CrowdInteractionSystem interactions;
        BottleneckTrafficController traffic;
        CrowdProfileStore profiles;
        CohortStore cohorts;
        CrowdWorldConfig config;
        std::unordered_map<std::uint64_t, FlowField> installed_flows;
        FlowHandle default_flow_handle;
        double maximum_agent_radius = 0.0;

        static Vec2 approach(const Vec2 &current, const Vec2 &target, double maximum_change);
        static std::uint64_t key(AgentHandle handle);
        static std::uint64_t key(FlowHandle handle);
        const FlowField *flow_for(const CrowdAgentState &agent) const;
        const DirectionalMotionField *directional_field_for(const CrowdAgentState &agent) const;
        Vec2 static_obstacle_repulsion(const CrowdAgentState &agent) const;
        void resolve_static_obstacle_overlaps(CrowdAgentState &agent) const;
        Vec2 resolve_motion(const CrowdAgentState &agent, const Vec2 &candidate,
                            const FlowField *flow) const;
        void recompute_maximum_agent_radius();

    public:
        explicit CrowdWorld(double spatial_cell_size = 32.0)
            : spatial(spatial_cell_size), static_obstacles(spatial_cell_size) {}

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
        bool set_agent_position(AgentHandle agent, const Vec2 &position, bool clear_velocity);
        bool set_agent_motion_limits(AgentHandle agent, double maximum_speed,
                                     double acceleration, double deceleration);
        bool set_agent_contact_profile(
            AgentHandle agent, double push_strength, double resistance,
            double cooldown, double impulse_decay, double control_suppression);
        bool set_agent_traffic_state(AgentHandle agent, std::int64_t group_token, int priority);
        std::vector<AgentHandle> query_agents(
            const Vec2 &position, double radius,
            std::uint32_t category_mask = std::numeric_limits<std::uint32_t>::max(),
            AgentHandle ignored = {}) const;
        std::vector<AgentHandle> query_agents_in_cone(
            const Vec2 &position, double radius, const Vec2 &direction,
            double angle_degrees, std::uint32_t category_mask,
            AgentHandle ignored = {}) const;
        std::vector<AgentHandle> query_agents_in_aabb(
            const Vec2 &center, double half_width, double half_height,
            std::uint32_t category_mask, AgentHandle ignored = {}) const;

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
        bool follow_directional_field(AgentHandle handle, DirectionalMotionFieldHandle field);
        bool stop_navigation(AgentHandle handle);
        bool set_paused(AgentHandle handle, bool paused);

        void apply_impulse(AgentHandle handle, const ImpulseRequest &request);
        std::size_t apply_impulses(const std::vector<AgentHandle> &handles,
                                   const std::vector<Vec2> &velocities,
                                   const ImpulseRequest &settings);
        ExternalVelocitySourceHandle create_external_velocity_source()
        { return external_velocity_sources.create(); }
        bool remove_external_velocity_source(ExternalVelocitySourceHandle source);
        bool refresh_external_velocity(AgentHandle handle, ExternalVelocitySourceHandle source,
                                       const Vec2 &velocity,
                                       double response_seconds, double expiry_seconds);
        bool release_external_velocity(AgentHandle handle, ExternalVelocitySourceHandle source);
        std::size_t external_velocity_source_count() const
        { return external_velocity_sources.size(); }
        EffectVolumeHandle create_effect_volume(const EffectVolumeConfig &config)
        { return effect_volumes.create(config); }
        bool update_effect_volume(EffectVolumeHandle handle, const Vec2 &position,
                                  const Vec2 &direction, const Vec2 &follow_offset)
        { return effect_volumes.update_transform(handle, position, direction, follow_offset); }
        bool remove_effect_volume(EffectVolumeHandle handle)
        { return effect_volumes.remove(handle); }
        std::vector<EffectVolumeEvent> take_effect_events()
        { return effect_volumes.take_events(); }
        std::size_t effect_volume_count() const { return effect_volumes.size(); }
        void configure_bottleneck(std::uint64_t bottleneck_id,
                                  const BottleneckTrafficConfig &config);
        bool request_bottleneck(std::uint64_t bottleneck_id, AgentHandle handle,
                                TrafficDirection direction, int priority = 0);
        bool has_bottleneck_access(std::uint64_t bottleneck_id, AgentHandle handle) const;
        void release_bottleneck(std::uint64_t bottleneck_id, AgentHandle handle);

        TerrainSpeedGrid &terrain_speed_grid() { return terrain_speeds; }
        const TerrainSpeedGrid &terrain_speed_grid() const { return terrain_speeds; }
        DirectionalMotionFieldHandle create_directional_field(
            const DirectionalMotionField &field);
        bool update_directional_field(DirectionalMotionFieldHandle handle,
                                      const DirectionalMotionField &field);
        bool remove_directional_field(DirectionalMotionFieldHandle handle);
        void clear_directional_fields();
        const DirectionalMotionField *get_directional_field(
            DirectionalMotionFieldHandle handle) const { return directional_fields.get(handle); }
        std::size_t directional_field_count() const { return directional_fields.size(); }
        StaticObstacleHandle create_static_obstacle(
            const Vec2 &position, double radius, double push_strength = 1.0);
        bool update_static_obstacle(StaticObstacleHandle handle, const Vec2 &position,
                                    double radius, double push_strength = 1.0);
        bool remove_static_obstacle(StaticObstacleHandle handle);
        void clear_static_obstacles() { static_obstacles.clear(); }
        std::size_t static_obstacle_count() const { return static_obstacles.size(); }
        const StaticObstacle *get_static_obstacle(StaticObstacleHandle handle) const
        { return static_obstacles.get(handle); }
        void update(double delta);
        std::size_t size() const { return agents.size(); }
        std::size_t profile_count() const { return profiles.size(); }
        std::size_t cohort_count() const { return cohorts.size(); }
        std::size_t installed_flow_count() const { return installed_flows.size(); }
    };
} // namespace ffcore
