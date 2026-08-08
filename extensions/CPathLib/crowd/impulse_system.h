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
        int priority = 0;
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
            double suppression_remaining = 0.0;
            bool preserve_navigation = false;
            bool stop_on_control_restore = false;
            int priority = 0;
        };

        std::unordered_map<std::uint64_t, State> states;
        static std::uint64_t key(AgentHandle handle);

    public:
        void apply(AgentHandle handle, const ImpulseRequest &request);
        void remove(AgentHandle handle);
        void update(double delta);
        Vec2 velocity(AgentHandle handle) const;
        double navigation_control(AgentHandle handle) const;
        bool cancel_if_navigation_opposes(AgentHandle handle,
                                          const Vec2 &navigation_velocity);
        bool active(AgentHandle handle) const;
    };
} // namespace ffcore
