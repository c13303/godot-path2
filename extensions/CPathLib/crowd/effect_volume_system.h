#pragma once

#include "agent_world.h"
#include "impulse_system.h"

#include <cstdint>
#include <limits>
#include <unordered_map>
#include <vector>

namespace ffcore
{
    struct EffectVolumeHandle
    {
        std::uint32_t index = 0;
        std::uint32_t generation = 0;
        bool is_valid() const { return index != 0; }
        bool operator==(const EffectVolumeHandle &other) const
        { return index == other.index && generation == other.generation; }
    };

    enum class EffectVolumeEventKind
    {
        Enter,
        Tick,
        Exit
    };

    enum class EffectImpulseDirection
    {
        Fixed,
        Radial
    };

    struct EffectVolumeConfig
    {
        Vec2 position;
        Vec2 direction = {1.0, 0.0};
        double radius = 1.0;
        double angle_degrees = 360.0;
        double duration = 0.0;
        double tick_interval = 0.0;
        std::uint32_t category_mask = std::numeric_limits<std::uint32_t>::max();
        AgentHandle ignored_agent;
        AgentHandle followed_agent;
        Vec2 follow_offset;
        std::int64_t caller_token = 0;
        bool apply_impulse_on_tick = false;
        EffectImpulseDirection impulse_direction = EffectImpulseDirection::Fixed;
        double impulse_speed = 0.0;
        double impulse_falloff = 0.0;
        ImpulseRequest impulse;
    };

    struct EffectVolumeEvent
    {
        EffectVolumeEventKind kind = EffectVolumeEventKind::Enter;
        EffectVolumeHandle volume;
        AgentHandle agent;
        Vec2 position;
        std::int64_t caller_token = 0;
    };

    struct EffectImpulseSubmission
    {
        AgentHandle agent;
        ImpulseRequest impulse;
    };

    class EffectVolumeSystem
    {
    private:
        struct MemberState
        {
            AgentHandle handle;
            double tick_remaining = 0.0;
            bool ticked_once = false;
        };

        struct Slot
        {
            std::uint32_t generation = 1;
            bool occupied = false;
            EffectVolumeConfig config;
            double remaining = 0.0;
            std::unordered_map<std::uint64_t, MemberState> members;
        };

        std::vector<Slot> slots = std::vector<Slot>(1);
        std::vector<EffectVolumeEvent> events;

        static std::uint64_t agent_key(AgentHandle handle);
        static EffectVolumeConfig sanitize(const EffectVolumeConfig &config);
        static bool contains(const EffectVolumeConfig &config,
                             const CrowdAgentState &agent);
        void emit_exit_events(EffectVolumeHandle handle, Slot &slot);

    public:
        EffectVolumeHandle create(const EffectVolumeConfig &config);
        bool update_transform(EffectVolumeHandle handle, const Vec2 &position,
                              const Vec2 &direction, const Vec2 &follow_offset);
        bool remove(EffectVolumeHandle handle);
        void remove_agent(AgentHandle handle);
        std::vector<EffectImpulseSubmission> update(double delta, const AgentWorld &agents);
        std::vector<EffectVolumeEvent> take_events();
        std::size_t size() const;
    };
} // namespace ffcore
