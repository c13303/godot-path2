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
            bool activated_this_update = false;
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
                    activated_this_update = true;
                }
            }
            const double previous_suppression = state.suppression_remaining;
            state.suppression_remaining = std::max(0.0, state.suppression_remaining - delta);
            if (state.stop_on_control_restore && previous_suppression > 0.0 &&
                state.suppression_remaining <= 0.0)
                state.active_velocity = {};
            if (!activated_this_update)
            {
                const double loss = std::clamp(state.active_decay, 0.0, 1.0);
                const double multiplier = loss >= 1.0
                    ? 0.0 : std::pow(1.0 - loss, delta);
                state.active_velocity = state.active_velocity * multiplier;
            }
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

    bool ImpulseSystem::cancel_if_navigation_opposes(
        AgentHandle handle, const Vec2 &navigation_velocity)
    {
        const auto state = states.find(key(handle));
        if (state == states.end() || state->second.preserve_navigation ||
            state->second.suppression_remaining > 0.0 ||
            state->second.active_velocity.is_zero() ||
            navigation_velocity.is_zero() ||
            state->second.active_velocity.dot(navigation_velocity) > 0.0)
            return false;
        states.erase(state);
        return true;
    }

    bool ImpulseSystem::active(AgentHandle handle) const
    {
        return states.find(key(handle)) != states.end();
    }
} // namespace ffcore
