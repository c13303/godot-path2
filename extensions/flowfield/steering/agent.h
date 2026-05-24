#pragma once

#include "../core/types.h"
#include <limits>

namespace ffcore
{
    struct GlobalConfig;
    class FlowField;

    enum class AgentControlMode
    {
        FlowField = 0,
        Manual = 1,
    };

    constexpr int SMASH_CLASS_PLAYER = 1 << 0;
    constexpr int SMASH_CLASS_MAIN_CHAR = 1 << 1;
    constexpr int SMASH_CLASS_MONSTER = 1 << 2;

    struct AgentProfile
    {
        double crowd_push_strength = 1.0;
        double crowd_resist_strength = 1.0;
        double world_radius = 0.0;
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
        Vec3 debug_color{};
        double target_radius_timer = 0.0;
        bool never_rest = false;

        void reset();
        void update_motion_state(double delta, const GlobalConfig &cfg, bool force_motion_state = false);
    };
} // namespace ffcore
