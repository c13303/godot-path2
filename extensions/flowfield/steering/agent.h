#pragma once

#include "../core/types.h"
#include <limits>
#include <vector>

namespace ffcore
{
    struct GlobalConfig;
    class FlowField;

    enum class AgentControlMode
    {
        FlowField = 0,
        Manual = 1,
    };

    // High-level mission phase, pushed from GDScript (building_manager / character).
    // State-derived in C++ for the debug overlay so it never desyncs from gameplay.
    enum class AgentPhase
    {
        None = 0,
        FlowIn = 1,   // following a flow field toward a garden
        AstarIn = 2,  // entered a garden, A* toward the plant
        Eating = 3,   // at the plant, eating (eating_seconds counts down)
        AstarOut = 4, // finished eating, A* out of the garden
        FlowOut = 5,  // left the garden, on the flow field toward the exit
        // Temporary holding state: the agent's garden assignment became invalid
        // (garden deleted/rebuilt) and it is queued for budgeted retargeting by
        // building_manager. Not gameplay behavior; the agent follows no path/flow
        // while in this state. Kept last so existing phase codes are unchanged.
        WaitingNewStatus = 6,
        Drowning = 7,
    };

    constexpr int SMASH_CLASS_PLAYER = 1 << 0;
    constexpr int SMASH_CLASS_MAIN_CHAR = 1 << 1;
    constexpr int SMASH_CLASS_MONSTER = 1 << 2;

    struct AgentProfile
    {
        double crowd_push_strength = 1.0;
        double crowd_resist_strength = 1.0;
        // Resistance to smash/knockback impulses (see apply_smash_impulse). 1.0 =
        // normal; 2.0 halves the received impulse velocity (twice the inertia).
        double smash_resist = 1.0;
        double world_radius = 0.0;
        double max_speed = std::numeric_limits<double>::quiet_NaN(); // NaN => inherit global agent_max_speed
        double foot_offset_y = std::numeric_limits<double>::quiet_NaN();
        double fight_offset_y = 0.0;
        double fight_half_w = 32.0;
        double fight_half_h = 32.0;
        int smash_class = SMASH_CLASS_MAIN_CHAR;
        bool weapon_immune = false;
    };

    struct AgentData
    {
        int id = -1;
        Vec2 position;
        Vec2 velocity;
        double max_speed = 50.0;
        bool active = true;
        AgentProfile profile{};

        FlowField *flow = nullptr;
        AgentControlMode control_mode = AgentControlMode::FlowField;
        Vec2 manual_input_dir{};
        double manual_acceleration = 900.0;
        double manual_deceleration = 1200.0;

        bool is_first = false;
        GroupID group = INVALID_GROUP;
        Vec2 smash_force{};
        bool is_propelled = false;
        double propelled_timer = 0.0;
        bool smash_just_reset = false;
        double smash_friction = -1.0; // perte de vitesse par seconde (0..1), -1 => fallback global
        double smash_control_suppression = 1.0;
        double smash_control_suppression_timer = 0.0;
        Vec2 pending_smash{};
        double smash_delay = 0.0;
        double pending_smash_friction = -1.0;
        double pending_smash_control_suppression = 1.0;
        double pending_smash_control_suppression_duration = 0.0;
        bool smash_pending = false;
        bool was_in_t2 = false;

        Vec2i last_logged_tile = Vec2i(-999999, -999999);
        bool moving = false;
        int dir_code = -1;
        int micro_osc = 0;
        double micro_osc_timer = 0.0;
        AgentPhase phase = AgentPhase::None;
        float eating_seconds = 0.0f;
        Vec3 debug_color{};
        Vec2 debug_nav_dir{};
        Vec2 debug_wall_repel{};
        Vec2 debug_separation{};
        Vec2 debug_desired_dir{};
        Vec2 debug_target_velocity{};
        int debug_bottleneck_core = -1;
        int debug_bottleneck_zone = -1;
        int active_bottleneck = -1;
        int completed_bottleneck = -1;
        bool debug_in_bottleneck_state = false;
        bool debug_bottleneck_wait = false;
        double debug_log_timer = 0.0;
        double target_radius_timer = 0.0;
        double lost_timer = 0.0;
        double stuck_in_wall_accum = 0.0;
        bool never_rest = false;
        // Hard freeze pushed from game-side (e.g. the seed merchant halting while the
        // player browses its shop). While set, the agent's velocity is zeroed every
        // tick and it skips all movement/path/flow integration, but its path/flow
        // assignment is preserved so it resumes exactly where it left off on unpause.
        bool paused = false;

        // Path-follow override: when path_active is true, the desired direction comes
        // from "toward path_waypoints[path_index]" instead of the flow field. The flow
        // field pointer is kept so wall-repulsion and bottleneck physics still work.
        // path_waypoints stores world-space waypoint centers.
        std::vector<Vec2> path_waypoints;
        int path_index = 0;
        bool path_active = false;
        bool path_arrived = false;

        void reset();
        void update_motion_state(double delta, const GlobalConfig &cfg, bool force_motion_state = false);
    };
} // namespace ffcore
