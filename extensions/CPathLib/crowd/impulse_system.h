#pragma once

#include "agent_world.h"

#include <unordered_map>

namespace ffcore
{
    struct ImpulseRequest
    {
        Vec2 velocity;
        double delay = 0.0;
        double decay_per_second = 4.0;
        double control_suppression_seconds = 0.0;
        bool preserve_navigation = false;
        bool stop_on_control_restore = false;
        bool apply_agent_resistance = false;
        bool feedback_enabled = true;
        int priority = 0;
    };

    /// Bounds every active impulse so a slow decay rate cannot leave an agent
    /// permanently displaced. Zero disables the corresponding bound.
    struct ImpulseResponseConfig
    {
        double speed_cap = 0.0;        // maximum magnitude accepted by apply()
        double maximum_duration = 0.0; // seconds an impulse may stay active
        double minimum_speed = 0.0;    // below this the impulse ends immediately
    };

    class ImpulseSystem
    {
    private:
        struct State
        {
            ImpulseRequest pending;
            bool has_pending = false;
            Vec2 active_velocity;
            double active_decay = 0.0;
            double active_remaining = 0.0;
            double suppression_remaining = 0.0;
            bool preserve_navigation = false;
            bool stop_on_control_restore = false;
            bool feedback_enabled = true;
            int priority = 0;
        };

        std::unordered_map<std::uint64_t, State> states;
        ImpulseResponseConfig response;
        static std::uint64_t key(AgentHandle handle);
        void end_active_impulse(State &state) const;

    public:
        void set_response_config(const ImpulseResponseConfig &config);
        const ImpulseResponseConfig &get_response_config() const { return response; }
        void apply(AgentHandle handle, const ImpulseRequest &request);
        void remove(AgentHandle handle);
        void update(double delta);
        Vec2 velocity(AgentHandle handle) const;
        double navigation_control(AgentHandle handle) const;
        bool cancel_if_navigation_opposes(AgentHandle handle,
                                          const Vec2 &navigation_velocity);
        bool active(AgentHandle handle) const;
        double suppression_remaining(AgentHandle handle) const;
        bool feedback_enabled(AgentHandle handle) const;
    };
} // namespace ffcore
