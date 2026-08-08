#include "effect_volume_system.h"

#include <algorithm>
#include <cmath>
#include <unordered_set>

namespace ffcore
{
    std::uint64_t EffectVolumeSystem::agent_key(AgentHandle handle)
    {
        return (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index;
    }

    EffectVolumeConfig EffectVolumeSystem::sanitize(const EffectVolumeConfig &requested)
    {
        EffectVolumeConfig config = requested;
        config.direction = config.direction.normalized();
        config.radius = std::isfinite(config.radius) ? std::max(0.0, config.radius) : 0.0;
        config.angle_degrees = std::isfinite(config.angle_degrees)
            ? std::clamp(config.angle_degrees, 0.0, 360.0) : 360.0;
        config.duration = std::isfinite(config.duration) ? std::max(0.0, config.duration) : 0.0;
        config.tick_interval = std::isfinite(config.tick_interval)
            ? std::max(0.0, config.tick_interval) : 0.0;
        config.impulse_speed = std::isfinite(config.impulse_speed)
            ? std::max(0.0, config.impulse_speed) : 0.0;
        config.impulse_falloff = std::isfinite(config.impulse_falloff)
            ? std::max(0.0, config.impulse_falloff) : 0.0;
        return config;
    }

    bool EffectVolumeSystem::contains(
        const EffectVolumeConfig &config, const CrowdAgentState &agent)
    {
        const Vec2 offset = agent.position - config.position;
        const double center_distance = offset.length();
        if (center_distance > config.radius + agent.profile.radius)
            return false;
        if (config.angle_degrees >= 360.0 || center_distance <= 1e-8)
            return true;
        if (config.direction.is_zero())
            return false;
        const double half_angle = config.angle_degrees * 0.5 *
            3.14159265358979323846 / 180.0;
        return offset.normalized().dot(config.direction) >= std::cos(half_angle);
    }

    EffectVolumeHandle EffectVolumeSystem::create(const EffectVolumeConfig &requested)
    {
        const EffectVolumeConfig config = sanitize(requested);
        if (config.radius <= 0.0 || config.duration <= 0.0 ||
            (config.angle_degrees < 360.0 && config.direction.is_zero()))
            return {};
        std::uint32_t index = 1;
        while (index < slots.size() && slots[index].occupied)
            ++index;
        if (index == slots.size())
            slots.push_back({});
        Slot &slot = slots[index];
        slot.occupied = true;
        slot.config = config;
        slot.remaining = config.duration;
        slot.members.clear();
        return {index, slot.generation};
    }

    bool EffectVolumeSystem::update_transform(
        EffectVolumeHandle handle, const Vec2 &position,
        const Vec2 &direction, const Vec2 &follow_offset)
    {
        if (handle.index >= slots.size())
            return false;
        Slot &slot = slots[handle.index];
        if (!slot.occupied || slot.generation != handle.generation ||
            !std::isfinite(position.x) || !std::isfinite(position.y) ||
            !std::isfinite(direction.x) || !std::isfinite(direction.y) ||
            !std::isfinite(follow_offset.x) || !std::isfinite(follow_offset.y))
            return false;
        const Vec2 normalized = direction.normalized();
        if (slot.config.angle_degrees < 360.0 && normalized.is_zero())
            return false;
        slot.config.position = position;
        slot.config.direction = normalized;
        slot.config.follow_offset = follow_offset;
        slot.remaining = slot.config.duration;
        return true;
    }

    void EffectVolumeSystem::emit_exit_events(EffectVolumeHandle handle, Slot &slot)
    {
        for (const auto &entry : slot.members)
        {
            events.push_back({EffectVolumeEventKind::Exit, handle,
                              entry.second.handle, slot.config.position,
                              slot.config.caller_token});
        }
        slot.members.clear();
    }

    bool EffectVolumeSystem::remove(EffectVolumeHandle handle)
    {
        if (handle.index >= slots.size())
            return false;
        Slot &slot = slots[handle.index];
        if (!slot.occupied || slot.generation != handle.generation)
            return false;
        emit_exit_events(handle, slot);
        slot.occupied = false;
        slot.config = {};
        slot.remaining = 0.0;
        ++slot.generation;
        if (slot.generation == 0)
            slot.generation = 1;
        return true;
    }

    void EffectVolumeSystem::remove_agent(AgentHandle handle)
    {
        const std::uint64_t key = agent_key(handle);
        for (std::size_t index = 1; index < slots.size(); ++index)
        {
            Slot &slot = slots[index];
            const auto member = slot.members.find(key);
            if (!slot.occupied || member == slot.members.end())
                continue;
            events.push_back({EffectVolumeEventKind::Exit,
                              {static_cast<std::uint32_t>(index), slot.generation},
                              handle, slot.config.position, slot.config.caller_token});
            slot.members.erase(member);
        }
    }

    std::vector<EffectImpulseSubmission> EffectVolumeSystem::update(
        double delta, const AgentWorld &agents)
    {
        std::vector<EffectImpulseSubmission> submissions;
        if (!std::isfinite(delta) || delta <= 0.0)
            return submissions;
        const std::vector<AgentHandle> agent_handles = agents.active_handles();
        for (std::size_t index = 1; index < slots.size(); ++index)
        {
            Slot &slot = slots[index];
            if (!slot.occupied)
                continue;
            const EffectVolumeHandle handle = {
                static_cast<std::uint32_t>(index), slot.generation};
            if (slot.config.followed_agent.is_valid())
            {
                const CrowdAgentState *owner = agents.get(slot.config.followed_agent);
                if (owner != nullptr)
                    slot.config.position = owner->position + slot.config.follow_offset;
            }

            std::unordered_set<std::uint64_t> inside;
            for (AgentHandle agent_handle : agent_handles)
            {
                const CrowdAgentState *agent = agents.get(agent_handle);
                if (agent == nullptr || agent_handle == slot.config.ignored_agent ||
                    (agent->profile.category_mask & slot.config.category_mask) == 0 ||
                    !contains(slot.config, *agent))
                    continue;
                const std::uint64_t key = agent_key(agent_handle);
                inside.insert(key);
                auto member = slot.members.find(key);
                if (member == slot.members.end())
                {
                    member = slot.members.emplace(key, MemberState{agent_handle, 0.0, false}).first;
                    events.push_back({EffectVolumeEventKind::Enter, handle, agent_handle,
                                      agent->position, slot.config.caller_token});
                }
                MemberState &state = member->second;
                state.tick_remaining -= delta;
                const bool should_tick = slot.config.tick_interval > 0.0
                    ? state.tick_remaining <= 0.0 : !state.ticked_once;
                if (!should_tick)
                    continue;
                state.ticked_once = true;
                state.tick_remaining = slot.config.tick_interval;
                events.push_back({EffectVolumeEventKind::Tick, handle, agent_handle,
                                  agent->position, slot.config.caller_token});
                if (slot.config.apply_impulse_on_tick && slot.config.impulse_speed > 0.0)
                {
                    ImpulseRequest impulse = slot.config.impulse;
                    Vec2 direction = slot.config.direction;
                    if (slot.config.impulse_direction == EffectImpulseDirection::Radial)
                    {
                        direction = (agent->position - slot.config.position).normalized();
                        if (direction.is_zero())
                        {
                            const double angle = static_cast<double>(agent_handle.index) *
                                2.399963229728653;
                            direction = {std::cos(angle), std::sin(angle)};
                        }
                    }
                    const double normalized_distance = slot.config.radius <= 0.0
                        ? 1.0 : std::clamp(
                            agent->position.distance_to(slot.config.position) /
                                slot.config.radius,
                            0.0, 1.0);
                    const double attenuation = std::pow(
                        std::max(0.0, 1.0 - normalized_distance),
                        slot.config.impulse_falloff);
                    impulse.velocity = direction.normalized() *
                        (slot.config.impulse_speed * attenuation);
                    submissions.push_back({agent_handle, impulse});
                }
            }

            for (auto member = slot.members.begin(); member != slot.members.end();)
            {
                if (inside.find(member->first) != inside.end())
                {
                    ++member;
                    continue;
                }
                events.push_back({EffectVolumeEventKind::Exit, handle,
                                  member->second.handle, slot.config.position,
                                  slot.config.caller_token});
                member = slot.members.erase(member);
            }

            slot.remaining -= delta;
            if (slot.remaining <= 0.0)
                remove(handle);
        }
        return submissions;
    }

    std::vector<EffectVolumeEvent> EffectVolumeSystem::take_events()
    {
        std::vector<EffectVolumeEvent> result;
        result.swap(events);
        return result;
    }

    std::size_t EffectVolumeSystem::size() const
    {
        return static_cast<std::size_t>(std::count_if(
            slots.begin(), slots.end(), [](const Slot &slot) { return slot.occupied; }));
    }
} // namespace ffcore
