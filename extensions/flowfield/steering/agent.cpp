#include "agent.h"

#include "../core/global_config.h"
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
} // namespace

namespace ffcore
{
    void AgentData::reset()
    {
        active = false;
        velocity = Vec2(0, 0);
        flow = nullptr;
        claimed_tile = Vec2i(-999999, -999999);
    }

    void AgentData::update_animation(double delta, bool in_claim_zone, const GlobalConfig &cfg, bool forceAnimation)
    {
        double thresh = std::max(0.0, cfg.walk_animation_threshold);
        double thresh2 = thresh * thresh;
        double vlen2 = velocity.length_squared();
        bool new_moving = vlen2 > thresh2;

        int new_dir = velocity_dir_code(velocity);
        bool dir_changed = (new_dir != dir_code);

        if (in_claim_zone && new_moving && dir_changed)
        {
            micro_osc += 1;
            micro_osc_timer = cfg.micro_osc_win_time;
        }

        if (micro_osc_timer > 0.0)
        {
            micro_osc_timer = std::max(0.0, micro_osc_timer - delta);
            if (micro_osc_timer <= 0.0)
                micro_osc = 0;
        }

        if (in_claim_zone && micro_osc >= cfg.micro_osc_limit_before_cancel) /// micro osc detected
        {
            reset();
            if (!forceAnimation)
                return;
        }

        if (micro_osc > 0 && !forceAnimation) // dont update animation if micro-oscillating
            return;

        if (new_moving != moving || new_dir != dir_code || forceAnimation) /// ACT THE UPDATE
        {
            moving = new_moving;
            dir_code = new_dir;
            update_animation_this_frame = true;
            /* godot::UtilityFunctions::print("Anim Changed Detected ", id, " velocity²=", vlen2, " threshold²=", thresh2); */
        }
    }
} // namespace ffcore
