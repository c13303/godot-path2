#include "agent.h"

#include "../core/global_config.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include <algorithm>
#include <cmath>

namespace
{
    inline int velocity_dir_code(const ffcore::Vec2 &v)
    {
        if (v.length_squared() < 1e-6)
            return -1;
        if (std::abs(v.x) >= std::abs(v.y))
            return v.x >= 0.0 ? 0 : 1; // E/W
        return v.y >= 0.0 ? 2 : 3;     // S/N
    }

    // True only when 'a' and 'b' are opposite cardinal codes (E<->W or N<->S).
    // A mere change of bucket (e.g. E->S while turning a corner) is NOT a reversal,
    // so smooth/curving travel does not count as oscillation.
    inline bool is_reversal(int a, int b)
    {
        if (a < 0 || b < 0)
            return false;
        return (a ^ b) == 1; // 0<->1 and 2<->3 differ only in the low bit
    }
} // namespace

namespace ffcore
{
void AgentData::reset()
{
    active = false;
    velocity = Vec2(0, 0);
    flow = nullptr;
    micro_osc = 0;
    micro_osc_timer = 0.0;
    target_radius_timer = 0.0;
    lost_timer = 0.0;
    stuck_in_wall_accum = 0.0;
    lost_slide_accum = 0.0;
    active_bottleneck = -1;
    completed_bottleneck = -1;
    debug_in_bottleneck_state = false;
    debug_bottleneck_wait = false;
    path_waypoints.clear();
    path_index = 0;
    path_active = false;
    path_arrived = false;
    traffic_group_id = 0;
    traffic_priority = 0;
    smash_force = Vec2(0, 0);
    is_propelled = false;
    propelled_timer = 0.0;
    smash_just_reset = false;
    smash_friction = -1.0;
    smash_control_suppression = 1.0;
    smash_control_suppression_timer = 0.0;
    smash_preserves_control = false;
    pending_smash = Vec2(0, 0);
    smash_delay = 0.0;
    pending_smash_friction = -1.0;
    pending_smash_control_suppression = 1.0;
    pending_smash_control_suppression_duration = 0.0;
    pending_smash_preserves_control = false;
    pending_smash_priority = static_cast<int>(ImpulseQueuePriority::None);
    smash_pending = false;
}

    void AgentData::update_motion_state(double delta, const GlobalConfig &cfg, bool force_motion_state)
    {
        double thresh = std::max(0.0, cfg.movement_threshold);
        double thresh2 = thresh * thresh;
        double vlen2 = velocity.length_squared();
        bool new_moving = vlen2 > thresh2;

        int new_dir = velocity_dir_code(velocity);
        bool dir_changed = (new_dir != dir_code);
        bool changed = dir_changed || (new_moving != moving);

        if (micro_osc_timer > 0.0)
        {
            micro_osc_timer = std::max(0.0, micro_osc_timer - delta);
            if (micro_osc_timer <= 0.0)
                micro_osc = 0;
        }

        // If an agent oscillates too much, cancel it
        if (micro_osc >= cfg.micro_osc_limit_before_cancel)
        {
            reset();
            if (!force_motion_state)
                return;
        }

        if (!changed && !force_motion_state)
            return;

        if (!force_motion_state)
        {
            // Only a genuine reversal (E<->W / N<->S) within the window counts as
            // oscillation. Turning a corner, curving, or starting/stopping motion is
            // normal path-following and must never raise micro_osc (false positives).
            if (is_reversal(dir_code, new_dir))
            {
                micro_osc += 1;
                micro_osc_timer = cfg.micro_osc_win_time;
                if (micro_osc >= cfg.micro_osc_limit_before_cancel)
                {
                    godot::UtilityFunctions::print("Micro osc overflow", id);
                    reset();
                    return;
                }
            }
        }
        else
        {
            micro_osc = 0;
            micro_osc_timer = 0.0;
        }

        if (changed || force_motion_state) /// ACT THE UPDATE
        {
            moving = new_moving;
            dir_code = new_dir;

            /*    if (force_motion_state)
               {
                   godot::UtilityFunctions::print("Forced motion state ", id, " velocity²=", vlen2, " threshold²=", thresh2);
               } */
        }
    }
} // namespace ffcore
