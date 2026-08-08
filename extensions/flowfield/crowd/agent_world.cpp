#include "agent_world.h"

#include <algorithm>
#include <cmath>

namespace ffcore
{
    AgentHandle AgentWorld::create(const Vec2 &position, const CrowdAgentProfile &requested)
    {
        std::uint32_t index = 1;
        while (index < slots.size() && slots[index].occupied)
            ++index;
        if (index == slots.size())
            slots.push_back({});

        CrowdAgentProfile profile = requested;
        profile.radius = std::isfinite(profile.radius) ? std::max(0.0, profile.radius) : 8.0;
        profile.maximum_speed = std::isfinite(profile.maximum_speed) ? std::max(0.0, profile.maximum_speed) : 80.0;
        profile.acceleration = std::isfinite(profile.acceleration) ? std::max(0.0, profile.acceleration) : 400.0;
        profile.deceleration = std::isfinite(profile.deceleration) ? std::max(0.0, profile.deceleration) : 500.0;
        profile.separation_radius = std::isfinite(profile.separation_radius) ? std::max(0.0, profile.separation_radius) : 20.0;
        profile.separation_weight = std::isfinite(profile.separation_weight) ? std::max(0.0, profile.separation_weight) : 1.0;
        profile.arrival_radius = std::isfinite(profile.arrival_radius) ? std::max(0.0, profile.arrival_radius) : 4.0;

        Slot &slot = slots[index];
        slot.occupied = true;
        slot.state = CrowdAgentState();
        slot.state.handle = {index, slot.generation};
        slot.state.position = position;
        slot.state.profile = profile;
        return slot.state.handle;
    }

    bool AgentWorld::remove(AgentHandle handle)
    {
        if (get(handle) == nullptr)
            return false;
        Slot &slot = slots[handle.index];
        slot.occupied = false;
        slot.state = CrowdAgentState();
        ++slot.generation;
        if (slot.generation == 0)
            slot.generation = 1;
        return true;
    }

    CrowdAgentState *AgentWorld::get(AgentHandle handle)
    {
        if (handle.index >= slots.size())
            return nullptr;
        Slot &slot = slots[handle.index];
        return slot.occupied && slot.generation == handle.generation ? &slot.state : nullptr;
    }

    const CrowdAgentState *AgentWorld::get(AgentHandle handle) const
    {
        if (handle.index >= slots.size())
            return nullptr;
        const Slot &slot = slots[handle.index];
        return slot.occupied && slot.generation == handle.generation ? &slot.state : nullptr;
    }

    std::vector<AgentHandle> AgentWorld::active_handles() const
    {
        std::vector<AgentHandle> handles;
        handles.reserve(size());
        for (std::size_t index = 1; index < slots.size(); ++index)
        {
            if (slots[index].occupied)
                handles.push_back(slots[index].state.handle);
        }
        return handles;
    }

    std::size_t AgentWorld::size() const
    {
        return static_cast<std::size_t>(std::count_if(
            slots.begin(), slots.end(), [](const Slot &slot) { return slot.occupied; }));
    }
} // namespace ffcore
