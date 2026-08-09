#include "impulse_system.h"

#include <algorithm>
#include <cmath>

namespace ffcore
{
    std::uint64_t ImpulseSystem::key(AgentHandle handle)
    {
        return (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index;
    }

    void ImpulseSystem::set_response_config(const ImpulseResponseConfig &config)
    {
        response.speed_cap = std::isfinite(config.speed_cap)
            ? std::max(0.0, config.speed_cap) : 0.0;
        response.maximum_duration = std::isfinite(config.maximum_duration)
            ? std::max(0.0, config.maximum_duration) : 0.0;
        response.minimum_speed = std::isfinite(config.minimum_speed)
            ? std::max(0.0, config.minimum_speed) : 0.0;
    }

    void ImpulseSystem::end_active_impulse(State &state) const
    {
        state.active_velocity = {};
        state.active_decay = 0.0;
        state.active_remaining = 0.0;
        state.suppression_remaining = 0.0;
        state.preserve_navigation = false;
        state.stop_on_control_restore = false;
        state.feedback_enabled = true;
    }

    void ImpulseSystem::apply(AgentHandle handle, const ImpulseRequest &requested)
    {
        if (!handle.is_valid() || !std::isfinite(requested.velocity.x) || !std::isfinite(requested.velocity.y))
            return;
        State &state = states[key(handle)];
        if ((state.has_pending || !state.active_velocity.is_zero()) && requested.priority < state.priority)
            return;
        state.pending = requested;
        // A single impulse may not exceed the configured launch speed, so one heavy hit
        // and a burst of light ones settle into the same recovery window.
        const double requested_speed = state.pending.velocity.length();
        if (response.speed_cap > 0.0 && requested_speed > response.speed_cap)
            state.pending.velocity = state.pending.velocity * (response.speed_cap / requested_speed);
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
                    state.active_remaining = response.maximum_duration;
                    state.suppression_remaining = state.pending.control_suppression_seconds;
                    state.preserve_navigation = state.pending.preserve_navigation;
                    state.stop_on_control_restore = state.pending.stop_on_control_restore;
                    state.feedback_enabled = state.pending.feedback_enabled;
                    state.has_pending = false;
                    activated_this_update = true;
                }
            }
            const double previous_suppression = state.suppression_remaining;
            state.suppression_remaining = std::max(0.0, state.suppression_remaining - delta);
            if (state.stop_on_control_restore && previous_suppression > 0.0 &&
                state.suppression_remaining <= 0.0)
                end_active_impulse(state);
            if (!activated_this_update && !state.active_velocity.is_zero())
            {
                const double loss = std::clamp(state.active_decay, 0.0, 1.0);
                const double multiplier = loss >= 1.0
                    ? 0.0 : std::pow(1.0 - loss, delta);
                state.active_velocity = state.active_velocity * multiplier;
                // Decay alone can trail on for minutes at a gentle loss rate. The
                // lifetime and the residual-speed floor are what actually hand the
                // agent back to its own navigation.
                if (response.maximum_duration > 0.0)
                {
                    state.active_remaining = std::max(0.0, state.active_remaining - delta);
                    if (state.active_remaining <= 0.0)
                        end_active_impulse(state);
                }
                if (state.active_velocity.length() < response.minimum_speed)
                    end_active_impulse(state);
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

    double ImpulseSystem::suppression_remaining(AgentHandle handle) const
    {
        const auto state = states.find(key(handle));
        return state == states.end() ? 0.0 : state->second.suppression_remaining;
    }

    bool ImpulseSystem::feedback_enabled(AgentHandle handle) const
    {
        const auto state = states.find(key(handle));
        return state == states.end() || state->second.feedback_enabled;
    }
} // namespace ffcore
