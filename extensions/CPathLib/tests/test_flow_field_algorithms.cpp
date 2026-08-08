#include "../flow/flow_field_algorithms.h"
#include "../flow/flow_field_builder.h"
#include "../bottleneck/bottleneck_analyzer.h"
#include "../core/navigation_world.h"
#include "../area/navigation_area.h"
#include "../area/portal_selector.h"
#include "../area/area_builder.h"
#include "../area/route_planner.h"
#include "../bottleneck/bottleneck_traffic_controller.h"
#include "../crowd/crowd_world.h"
#include "../jobs/flow_field_job_queue.h"

#include <cmath>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <thread>

namespace
{
    using ffcore::Vec2i;

    void require(bool condition, const char *message)
    {
        if (!condition)
        {
            std::cerr << "FlowFieldAlgorithms test failed: " << message << '\n';
            std::exit(EXIT_FAILURE);
        }
    }

    bool approximately(double actual, double expected)
    {
        return std::abs(actual - expected) <= 1e-6;
    }

    ffcore::CellSet rectangle(int width, int height, Vec2i origin = Vec2i())
    {
        ffcore::CellSet cells;
        for (int y = 0; y < height; ++y)
        {
            for (int x = 0; x < width; ++x)
                cells.insert({origin.x + x, origin.y + y});
        }
        return cells;
    }

    void test_integration_costs()
    {
        const ffcore::CellSet walkable = rectangle(3, 3);
        const ffcore::IntegrationCosts costs =
            ffcore::FlowFieldAlgorithms::compute_integration_costs(walkable, {2, 2});
        require(approximately(costs.at({2, 2}), 0.0), "goal cost should be zero");
        require(approximately(costs.at({1, 1}), 1.41421356237), "diagonal cost changed");
        require(approximately(costs.at({0, 0}), 2.0 * 1.41421356237), "route integration changed");
    }

    void test_corner_cutting_and_directional_edges()
    {
        ffcore::CellSet diagonal_only = {{0, 0}, {1, 1}};
        const ffcore::IntegrationCosts blocked_diagonal =
            ffcore::FlowFieldAlgorithms::compute_integration_costs(diagonal_only, {1, 1});
        require(std::isinf(blocked_diagonal.at({0, 0})), "integration must forbid corner cutting");

        const ffcore::CellSet corridor = {{0, 0}, {1, 0}, {2, 0}};
        ffcore::DirectionalTraversalConstraints constraints;
        constraints[{1, 0}] = {-1, 0};
        const ffcore::IntegrationCosts directed =
            ffcore::FlowFieldAlgorithms::compute_integration_costs(corridor, {2, 0}, &constraints);
        require(std::isinf(directed.at({0, 0})), "directional source constraint should block the route");
        require(std::isinf(directed.at({1, 0})), "constrained source should not reach the goal");
    }

    void test_missing_goal()
    {
        const ffcore::CellSet walkable = {{0, 0}, {1, 0}};
        const ffcore::IntegrationCosts costs =
            ffcore::FlowFieldAlgorithms::compute_integration_costs(walkable, {2, 0});
        require(costs.size() == walkable.size(), "missing goal should preserve the walkable cost map");
        require(std::isinf(costs.at({0, 0})) && std::isinf(costs.at({1, 0})),
                "missing goal should leave every cell unreachable");
    }

    void test_distance_field_with_nonzero_origin()
    {
        ffcore::CellSet walls = {{11, 21}};
        const std::vector<float> distances =
            ffcore::FlowFieldAlgorithms::compute_wall_distance_field(3, 3, {10, 20}, walls);
        require(distances.size() == 9, "distance field dimensions changed");
        require(approximately(distances[4], 0.0), "wall distance should be zero");
        require(approximately(distances[3], 1.0), "cardinal wall distance should be one");
        require(approximately(distances[0], 1.4142), "legacy diagonal wall distance changed");
        require(approximately(distances[8], 1.4142), "reverse-pass diagonal wall distance changed");
    }

    void test_generated_directions()
    {
        const ffcore::CellSet walkable = rectangle(3, 3);
        const ffcore::IntegrationCosts costs =
            ffcore::FlowFieldAlgorithms::compute_integration_costs(walkable, {2, 2});
        const std::vector<float> distances(9, 1e9f);
        const std::vector<ffcore::Vec2> directions = ffcore::FlowFieldAlgorithms::generate_directions(
            3, 3, {0, 0}, walkable, costs, distances, 0.0);
        require(directions.size() == 9, "direction field dimensions changed");
        require(approximately(directions[0].x, 0.70710678118) &&
                    approximately(directions[0].y, 0.70710678118),
                "open-grid direction should point diagonally toward the goal");
        require(directions[8].is_zero(), "goal direction should remain zero");
    }

    void test_clearance_breaks_equal_cost_ties()
    {
        const ffcore::CellSet walkable = rectangle(3, 3);
        ffcore::IntegrationCosts costs;
        for (const Vec2i &cell : walkable)
            costs[cell] = 2.0;
        costs[{2, 1}] = 1.0;
        costs[{1, 0}] = 1.0;

        const std::vector<float> distances = {
            3.0f, 3.0f, 3.0f,
            2.0f, 2.0f, 2.0f,
            1.0f, 1.0f, 1.0f,
        };
        const std::vector<ffcore::Vec2> directions = ffcore::FlowFieldAlgorithms::generate_directions(
            3, 3, {0, 0}, walkable, costs, distances, 2.0);
        require(approximately(directions[4].x, 0.0) && approximately(directions[4].y, -1.0),
                "clearance gradient should break an equal-cost tie toward open space");
    }

    void test_bottleneck_detection()
    {
        ffcore::CellSet walkable;
        for (int y = 0; y < 3; ++y)
        {
            walkable.insert({0, y});
            walkable.insert({1, y});
            walkable.insert({3, y});
            walkable.insert({4, y});
        }
        walkable.insert({2, 1});
        const ffcore::IntegrationCosts costs =
            ffcore::FlowFieldAlgorithms::compute_integration_costs(walkable, {4, 1});
        const std::vector<ffcore::DetectedBottleneck> bottlenecks =
            ffcore::BottleneckAnalyzer::analyze(walkable, costs, 1);
        require(bottlenecks.size() == 1, "single-cell doorway should produce one bottleneck");
        require(bottlenecks[0].cell == Vec2i(2, 1) && bottlenecks[0].axis == 1,
                "doorway bottleneck identity changed");
        require(bottlenecks[0].zone_cells.size() == 3,
                "radius-one bottleneck zone should include reachable cardinal cells");
    }

    void test_complete_portable_build()
    {
        ffcore::FlowFieldBuildRequest request;
        request.width = 3;
        request.height = 3;
        request.tile_size = 16.0;
        request.cell_origin = {10, 20};
        request.world_origin = {100.0, -50.0};
        request.goal_cell = {12, 22};
        request.walkable_cells = rectangle(3, 3, request.cell_origin);
        request.physical_wall_cells = {{11, 20}};
        request.wall_clearance_weight = 0.5;
        request.detect_bottlenecks = true;
        request.bottleneck_zone_radius = 1;

        const ffcore::FlowFieldBuildResult result = ffcore::FlowFieldBuilder::build(request);
        require(result.ok, "complete portable flow build should succeed");
        require(result.field.width() == 3 && result.field.height() == 3,
                "complete build dimensions changed");
        require(result.field.get_cell_origin() == Vec2i(10, 20),
                "complete build origin changed");
        require(result.field.get_goal_cell() == Vec2i(2, 2),
                "complete build relative goal changed");
        require(result.field.cell_to_world({0, 0}).distance_to({268.0, 278.0}) <= 1e-6,
                "non-zero world origin conversion changed");
        require(result.field.is_cell_physics_passable({1, 0}) == false,
                "physical wall mask changed");
        require(result.field.dir(0, 0).is_zero() == false,
                "reachable cell should receive a direction");
    }

    void test_navigability_is_distinct_from_reachability()
    {
        ffcore::FlowFieldBuildRequest request;
        request.width = 3;
        request.height = 1;
        request.goal_cell = {2, 0};
        request.walkable_cells = {{0, 0}, {2, 0}};
        const ffcore::FlowFieldBuildResult result = ffcore::FlowFieldBuilder::build(request);
        require(result.ok, "disconnected generic flow fixture should still build");
        require(result.field.is_cell_navigable({0, 0}),
                "generic navigability must describe topology, not goal reachability");
        require(result.field.dir(0, 0).is_zero(),
                "unreachable navigable cell must retain a zero flow direction");
    }

    void test_instance_owned_navigation_world()
    {
        ffcore::NavigationWorld first_world;
        ffcore::NavigationWorld second_world;
        ffcore::GridDefinition definition;
        definition.width = 3;
        definition.height = 3;
        definition.cell_size = 24.0;
        const ffcore::CellSet walkable_set = rectangle(3, 3);
        const std::vector<Vec2i> walkable(walkable_set.begin(), walkable_set.end());
        require(first_world.set_grid(definition, walkable), "first world grid setup failed");
        require(second_world.set_grid(definition, walkable), "second world grid setup failed");
        require(first_world.set_cell_walkable({1, 1}, false), "topology edit should change first world");
        require(first_world.get_topology_revision() != second_world.get_topology_revision(),
                "independent worlds must not share revisions");
        const std::uint64_t cost_before_config = first_world.get_cost_revision();
        ffcore::NavigationWorldConfig changed_config;
        changed_config.flow_wall_clearance_weight = 0.25;
        first_world.set_config(changed_config);
        require(first_world.get_cost_revision() == cost_before_config + 1,
                "flow configuration edit should invalidate the cost revision");
        require(first_world.find_path({0, 0}, {2, 2}).status == ffcore::NavigationStatus::Found,
                "instance-owned world path query failed");
        require(second_world.build_flow({2, 2}).status == ffcore::NavigationStatus::Found,
                "instance-owned world flow query failed");
        const std::uint64_t second_cost_before = second_world.get_cost_revision();
        require(second_world.set_cell_traversal_cost({1, 1}, 20.0),
                "instance-owned traversal cost edit failed");
        require(second_world.get_cost_revision() == second_cost_before + 1,
                "cost edit should increment only its owning world's revision");
        const ffcore::WorldPathResult weighted = second_world.find_path({0, 0}, {2, 2});
        require(weighted.cells.size() > 3 && weighted.cells[1] != Vec2i(1, 1),
                "navigation world should apply weighted A* costs");
    }

    void test_area_and_portal_handles()
    {
        ffcore::NavigationAreaStore store;
        const ffcore::AreaHandle area = store.create_area(
            {{1, 1}, {2, 1}, {1, 2}, {2, 2}}, {{2, 2}});
        require(area.is_valid(), "explicit area creation failed");
        const ffcore::PortalHandle portal = store.create_portal(
            area, {{1, 1}, {1, 2}}, {{0, 1}, {0, 2}}, ffcore::PortalDirection::Both, 2);
        require(portal.is_valid(), "multi-cell portal creation failed");
        require(store.get_area(area)->portals.size() == 1, "area should own its portal handle");
        require(store.get_portal(portal)->capacity == 2, "portal capacity changed");
        require(store.remove_area(area), "area removal failed");
        require(store.get_area(area) == nullptr && store.get_portal(portal) == nullptr,
                "stale generational handles should fail safely");
        const ffcore::AreaHandle replacement = store.create_area({{5, 5}});
        require(replacement.index == area.index && replacement.generation != area.generation,
                "reused area slot should advance its generation");
    }

    void test_route_cost_portal_selection()
    {
        ffcore::NavigationAreaStore store;
        const ffcore::AreaHandle area_handle = store.create_area({{3, 0}, {3, 1}});
        const ffcore::PortalHandle near_portal = store.create_portal(
            area_handle, {{3, 0}}, {{2, 0}}, ffcore::PortalDirection::Both, 1);
        store.create_portal(
            area_handle, {{3, 1}}, {{2, 1}}, ffcore::PortalDirection::Both, 1);
        const ffcore::CellSet walkable = rectangle(4, 2);
        const ffcore::PortalSelectionResult selected = ffcore::PortalSelector::select(
            store, *store.get_area(area_handle), {0, 0}, walkable, ffcore::PortalUse::Enter);
        require(selected.found && selected.portal == near_portal,
                "portal selector should choose the lowest route-cost entrance");
    }

    void test_async_flow_job_queue()
    {
        ffcore::FlowFieldBuildRequest request;
        request.width = 3;
        request.height = 3;
        request.tile_size = 16.0;
        request.goal_cell = {2, 2};
        request.walkable_cells = rectangle(3, 3);
        ffcore::FlowFieldJobQueue queue;
        const std::uint64_t id = queue.submit(request, 4, 7);
        ffcore::FlowFieldJobResult result;
        for (int attempt = 0; attempt < 200 && !queue.take_completed(result); ++attempt)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        require(result.request_id == id && result.build.ok,
                "portable async flow job did not complete");
        require(result.topology_revision == 4 && result.cost_revision == 7,
                "portable async flow revisions changed");
    }

    void test_area_building_and_route_segments()
    {
        const ffcore::CellSet allowed = {{3, 0}, {4, 0}, {4, 1}, {9, 9}};
        const ffcore::AreaBuildResult seeded = ffcore::AreaBuilder::from_seed({3, 0}, allowed);
        require(seeded.interior_cells.size() == 3,
                "seeded area must stay inside its connected component");
        require(seeded.boundary_cells.size() == 3,
                "seeded area boundary calculation changed");

        ffcore::NavigationAreaStore store;
        const ffcore::AreaHandle area = store.create_area({{3, 0}, {4, 0}});
        store.create_portal(area, {{3, 0}}, {{2, 0}}, ffcore::PortalDirection::Both, 1);
        const ffcore::CellSet world = {{0, 0}, {1, 0}, {2, 0}};
        const ffcore::RoutePlan enter = ffcore::RoutePlanner::plan_enter(
            store, area, {0, 0}, {4, 0}, world, 12);
        require(enter.status == ffcore::RouteStatus::Found && enter.segments.size() == 3,
                "enter route should contain world, crossing, and local segments");
        require(enter.segments[0].type == ffcore::RouteSegmentType::WorldPath &&
                    enter.segments[1].type == ffcore::RouteSegmentType::PortalCrossing &&
                    enter.segments[2].type == ffcore::RouteSegmentType::AreaPath,
                "enter route segment order changed");
        const ffcore::RoutePlan leave = ffcore::RoutePlanner::plan_exit(
            store, area, {4, 0}, {0, 0}, world, 12);
        require(leave.status == ffcore::RouteStatus::Found && leave.segments.size() == 3,
                "exit route should contain local, crossing, and world segments");
        require(enter.is_current(12, store), "fresh route should be current");
        store.create_portal(area, {{4, 0}}, {{5, 0}}, ffcore::PortalDirection::Both, 1);
        require(!enter.is_current(12, store), "area edit should make an existing route stale");
    }

    void test_bottleneck_traffic_fairness()
    {
        ffcore::BottleneckTrafficController traffic;
        traffic.configure(7, {1, 1.0});
        require(traffic.request(7, 1, ffcore::TrafficDirection::Forward),
                "first bottleneck request should be granted");
        require(!traffic.request(7, 2, ffcore::TrafficDirection::Forward),
                "capacity must queue a second same-direction agent");
        require(!traffic.request(7, 3, ffcore::TrafficDirection::Reverse),
                "opposing agent must wait while bottleneck is occupied");
        traffic.release(7, 1);
        require(traffic.is_granted(7, 3) && !traffic.is_granted(7, 2),
                "empty bottleneck should alternate direction fairly");
        traffic.update(1.1);
        require(traffic.is_granted(7, 2),
                "expired reservation should release capacity to waiting traffic");
    }

    void test_generic_crowd_motion_and_forces()
    {
        ffcore::FlowFieldBuildRequest flow_request;
        flow_request.width = 5;
        flow_request.height = 1;
        flow_request.tile_size = 1.0;
        flow_request.goal_cell = {4, 0};
        flow_request.walkable_cells = rectangle(5, 1);
        const ffcore::FlowFieldBuildResult flow = ffcore::FlowFieldBuilder::build(flow_request);
        require(flow.ok, "crowd fixture flow failed to build");

        ffcore::CrowdWorld crowd(1.0);
        crowd.set_shared_flow(flow.field);
        ffcore::CrowdAgentProfile profile;
        profile.radius = 0.1;
        profile.maximum_speed = 2.0;
        profile.acceleration = 20.0;
        profile.deceleration = 20.0;
        profile.separation_radius = 0.5;
        const ffcore::AgentHandle flow_agent = crowd.add_agent({0.5, 0.5}, profile);
        require(crowd.follow_flow(flow_agent), "agent should attach to the shared flow");
        crowd.update(0.1);
        require(crowd.get_agent(flow_agent)->position.x > 0.5,
                "flow-driven crowd agent should advance toward the goal");

        const ffcore::AgentHandle impulse_agent = crowd.add_agent({0.5, 0.5}, profile);
        ffcore::ImpulseRequest impulse;
        impulse.velocity = {3.0, 0.0};
        impulse.decay_per_second = 0.0;
        impulse.preserve_navigation = true;
        crowd.apply_impulse(impulse_agent, impulse);
        crowd.update(0.1);
        require(crowd.get_agent(impulse_agent)->position.x > 0.5,
                "immediate generic impulse should alter position");
        require(crowd.refresh_external_velocity(impulse_agent, 4, {1.0, 0.0}, 0.0, 1.0),
                "persistent external velocity source should attach");
        const double before_external = crowd.get_agent(impulse_agent)->position.x;
        crowd.update(0.1);
        require(crowd.get_agent(impulse_agent)->position.x > before_external,
                "persistent external velocity should contribute motion");

        require(crowd.remove_agent(flow_agent), "agent removal should succeed");
        require(crowd.get_agent(flow_agent) == nullptr,
                "stale generational agent handle should fail safely");
    }

    void test_generational_multi_flow_store()
    {
        ffcore::NavigationWorld world;
        ffcore::GridDefinition definition;
        definition.width = 5;
        definition.height = 1;
        definition.cell_size = 1.0;
        const ffcore::CellSet walkable_set = rectangle(5, 1);
        require(world.set_grid(
                    definition,
                    std::vector<Vec2i>(walkable_set.begin(), walkable_set.end())),
                "multi-flow fixture grid setup failed");

        const ffcore::FlowHandle left = world.create_flow({0, 0});
        const ffcore::FlowHandle right = world.create_flow({4, 0});
        const ffcore::StoredFlow *left_flow = world.get_flow(left);
        const ffcore::StoredFlow *right_flow = world.get_flow(right);
        require(left_flow != nullptr && left_flow->status == ffcore::FlowStatus::Ready,
                "left flow handle should resolve to a ready field");
        require(right_flow != nullptr && right_flow->status == ffcore::FlowStatus::Ready,
                "right flow handle should resolve to a ready field");
        require(left_flow->field.compute_flow_dir({2.5, 0.5}).x < 0.0 &&
                    right_flow->field.compute_flow_dir({2.5, 0.5}).x > 0.0,
                "independent flow handles should preserve different destinations");

        require(world.set_cell_traversal_cost({2, 0}, 2.0),
                "flow invalidation fixture cost edit failed");
        require(world.get_flow(left)->status == ffcore::FlowStatus::Stale &&
                    world.get_flow(right)->status == ffcore::FlowStatus::Stale,
                "world edits should stale every owned flow");
        require(world.release_flow(left), "flow release should succeed");
        const ffcore::FlowHandle replacement = world.create_flow({0, 0});
        require(replacement.index == left.index && replacement.generation != left.generation,
                "reused flow slot should advance its generation");
        require(world.get_flow(left) == nullptr,
                "stale flow handle should fail safely after slot reuse");
        const ffcore::FlowHandle cancelled = world.begin_flow_request({4, 0});
        require(world.set_flow_status(cancelled, ffcore::FlowStatus::Cancelled),
                "pending flow cancellation should succeed");
        require(world.set_cell_traversal_cost({3, 0}, 3.0),
                "cancelled-flow fixture cost edit failed");
        require(world.get_flow(cancelled)->status == ffcore::FlowStatus::Cancelled,
                "world invalidation must not resurrect a cancelled flow");
    }

    void test_profiles_cohorts_and_multi_flow_assignment()
    {
        ffcore::FlowFieldBuildRequest left_request;
        left_request.width = 5;
        left_request.height = 1;
        left_request.tile_size = 1.0;
        left_request.goal_cell = {0, 0};
        left_request.walkable_cells = rectangle(5, 1);
        ffcore::FlowFieldBuildRequest right_request = left_request;
        right_request.goal_cell = {4, 0};
        const ffcore::FlowFieldBuildResult left = ffcore::FlowFieldBuilder::build(left_request);
        const ffcore::FlowFieldBuildResult right = ffcore::FlowFieldBuilder::build(right_request);
        require(left.ok && right.ok, "cohort multi-flow fixtures failed to build");

        ffcore::CrowdWorld first_world(1.0);
        ffcore::CrowdWorld second_world(1.0);
        ffcore::CrowdWorldConfig first_config;
        first_config.default_agent_profile.maximum_speed = 3.0;
        first_world.set_config(first_config);
        require(approximately(first_world.get_config().default_agent_profile.maximum_speed, 3.0) &&
                    approximately(second_world.get_config().default_agent_profile.maximum_speed, 80.0),
                "crowd defaults must be owned by each world instance");

        ffcore::CrowdAgentProfile profile;
        profile.radius = 0.1;
        profile.maximum_speed = 2.0;
        profile.acceleration = 20.0;
        profile.deceleration = 20.0;
        profile.separation_radius = 0.0;
        const ffcore::ProfileHandle profile_handle = first_world.create_profile(profile);
        const ffcore::AgentHandle left_agent = first_world.add_agent({3.5, 0.5}, profile_handle);
        const ffcore::AgentHandle right_agent = first_world.add_agent({1.5, 0.5}, profile_handle);
        require(left_agent.is_valid() && right_agent.is_valid(),
                "agents should be created from reusable profiles");

        const ffcore::FlowHandle left_handle = {3, 1};
        const ffcore::FlowHandle right_handle = {7, 2};
        require(first_world.install_flow(left_handle, left.field) &&
                    first_world.install_flow(right_handle, right.field),
                "crowd should install multiple independent flow handles");
        const ffcore::CohortHandle left_cohort = first_world.create_cohort();
        const ffcore::CohortHandle right_cohort = first_world.create_cohort();
        require(first_world.assign_agent_to_cohort(left_agent, left_cohort) &&
                    first_world.assign_agent_to_cohort(right_agent, right_cohort),
                "agents should join independent cohorts");
        require(first_world.assign_cohort_flow(left_cohort, left_handle) &&
                    first_world.assign_cohort_flow(right_cohort, right_handle),
                "cohorts should select independent flows");
        require(first_world.cohort_member_count(left_cohort) == 1 &&
                    first_world.cohort_member_count(right_cohort) == 1,
                "cohort membership counts changed");

        first_world.update(0.1);
        require(first_world.get_agent(left_agent)->position.x < 3.5 &&
                    first_world.get_agent(right_agent)->position.x > 1.5,
                "agents assigned to different cohort flows should move in opposite directions");
        require(first_world.remove_cohort(left_cohort), "cohort removal should succeed");
        const ffcore::CohortHandle replacement = first_world.create_cohort();
        require(replacement.index == left_cohort.index &&
                    replacement.generation != left_cohort.generation,
                "reused cohort slot should advance its generation");
        require(first_world.remove_profile(profile_handle), "profile removal should succeed");
        const ffcore::ProfileHandle replacement_profile = first_world.create_profile(profile);
        require(replacement_profile.index == profile_handle.index &&
                    replacement_profile.generation != profile_handle.generation,
                "reused profile slot should advance its generation");
    }
}

int main()
{
    test_integration_costs();
    test_corner_cutting_and_directional_edges();
    test_missing_goal();
    test_distance_field_with_nonzero_origin();
    test_generated_directions();
    test_clearance_breaks_equal_cost_ties();
    test_bottleneck_detection();
    test_complete_portable_build();
    test_navigability_is_distinct_from_reachability();
    test_instance_owned_navigation_world();
    test_area_and_portal_handles();
    test_route_cost_portal_selection();
    test_async_flow_job_queue();
    test_area_building_and_route_segments();
    test_bottleneck_traffic_fairness();
    test_generic_crowd_motion_and_forces();
    test_generational_multi_flow_store();
    test_profiles_cohorts_and_multi_flow_assignment();
    std::cout << "FlowFieldAlgorithms tests passed\n";
    return EXIT_SUCCESS;
}
