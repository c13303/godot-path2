#include "impulse_system.h"

#include <algorithm>
#include <cmath>

namespace ffcore
{
    std::uint64_t ImpulseSystem::key(AgentHandle handle)
    {
        return (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index;
    }

    void ImpulseSystem::apply(AgentHandle handle, const ImpulseRequest &requested)
    {
        if (!handle.is_valid() || !std::isfinite(requested.velocity.x) || !std::isfinite(requested.velocity.y))
            return;
        State &state = states[key(handle)];
        if ((state.has_pending || !state.active_velocity.is_zero()) && requested.priority < state.priority)
            return;
        state.pending = requested;
        state.pending.delay = std::isfinite(requested.delay) ? std::max(0.0, requested.delay) : 0.0;
        state.pending.decay_per_second = std::isfinite(requested.decay_per_second)
            ? std::max(0.0, requested.decay_per_second) : 4.0;
        state.pending.control_suppression_seconds = std::isfinite(requested.control_suppression_seconds)
            ? std::max(0.0, requested.control_suppression_seconds) : 0.0;
        state.has_pending = true;
        state.priority = requested.priority;
    }

    void ImpulseSystem::remove(AgentHandle handle)
    {
        states.erase(key(handle));
    }

    void ImpulseSystem::update(double delta)
    {
        if (!std::isfinite(delta) || delta <= 0.0)
            return;
        for (auto iterator = states.begin(); iterator != states.end();)
        {
            State &state = iterator->second;
            if (state.has_pending)
            {
                state.pending.delay -= delta;
                if (state.pending.delay <= 0.0)
                {
                    state.active_velocity = state.pending.velocity;
                    state.active_decay = state.pending.decay_per_second;
                    state.suppression_remaining = state.pending.control_suppression_seconds;
                    state.preserve_navigation = state.pending.preserve_navigation;
                    state.stop_on_control_restore = state.pending.stop_on_control_restore;
                    state.has_pending = false;
                }
            }
            const double previous_suppression = state.suppression_remaining;
            state.suppression_remaining = std::max(0.0, state.suppression_remaining - delta);
            if (state.stop_on_control_restore && previous_suppression > 0.0 &&
                state.suppression_remaining <= 0.0)
                state.active_velocity = {};
            const double multiplier = std::max(0.0, 1.0 - state.active_decay * delta);
            state.active_velocity = state.active_velocity * multiplier;
            if (state.active_velocity.length_squared() < 1e-8)
                state.active_velocity = {};
            if (!state.has_pending && state.active_velocity.is_zero() && state.suppression_remaining <= 0.0)
                iterator = states.erase(iterator);
            else
                ++iterator;
        }
    }

    Vec2 ImpulseSystem::velocity(AgentHandle handle) const
    {
        const auto state = states.find(key(handle));
        return state == states.end() ? Vec2() : state->second.active_velocity;
    }

    double ImpulseSystem::navigation_control(AgentHandle handle) const
    {
        const auto state = states.find(key(handle));
        if (state == states.end() || state->second.preserve_navigation)
            return 1.0;
        return state->second.suppression_remaining > 0.0 ? 0.0 : 1.0;
    }

    bool ImpulseSystem::active(AgentHandle handle) const
    {
        return states.find(key(handle)) != states.end();
    }
} // namespace ffcore
