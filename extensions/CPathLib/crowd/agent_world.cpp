#include "agent_world.h"

namespace ffcore
{
    AgentHandle AgentWorld::create(const Vec2 &position, const CrowdAgentProfile &requested)
    {
        std::uint32_t index = 1;
        while (index < slots.size() && slots[index].occupied)
            ++index;
        if (index == slots.size())
            slots.push_back({});

        Slot &slot = slots[index];
        slot.occupied = true;
        slot.state = CrowdAgentState();
        slot.state.handle = {index, slot.generation};
        slot.state.position = position;
        slot.state.profile = CrowdProfileStore::sanitize(requested);
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
