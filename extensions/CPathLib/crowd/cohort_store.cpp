#include "cohort_store.h"

#include <algorithm>

namespace ffcore
{
    CohortHandle CohortStore::create()
    {
        std::uint32_t index = 1;
        while (index < slots.size() && slots[index].occupied)
            ++index;
        if (index == slots.size())
            slots.push_back({});
        Slot &slot = slots[index];
        slot.occupied = true;
        slot.state = CohortState();
        slot.state.handle = {index, slot.generation};
        return slot.state.handle;
    }

    bool CohortStore::remove(CohortHandle handle)
    {
        if (get(handle) == nullptr)
            return false;
        Slot &slot = slots[handle.index];
        slot.occupied = false;
        slot.state = CohortState();
        ++slot.generation;
        if (slot.generation == 0)
            slot.generation = 1;
        return true;
    }

    CohortState *CohortStore::get(CohortHandle handle)
    {
        if (handle.index >= slots.size())
            return nullptr;
        Slot &slot = slots[handle.index];
        return slot.occupied && slot.generation == handle.generation ? &slot.state : nullptr;
    }

    const CohortState *CohortStore::get(CohortHandle handle) const
    {
        if (handle.index >= slots.size())
            return nullptr;
        const Slot &slot = slots[handle.index];
        return slot.occupied && slot.generation == handle.generation ? &slot.state : nullptr;
    }

    bool CohortStore::add_member(CohortHandle cohort, AgentHandle agent)
    {
        CohortState *state = get(cohort);
        if (state == nullptr || !agent.is_valid())
            return false;
        if (std::find(state->members.begin(), state->members.end(), agent) != state->members.end())
            return true;
        state->members.push_back(agent);
        return true;
    }

    bool CohortStore::remove_member(CohortHandle cohort, AgentHandle agent)
    {
        CohortState *state = get(cohort);
        if (state == nullptr)
            return false;
        const auto existing = std::find(state->members.begin(), state->members.end(), agent);
        if (existing == state->members.end())
            return false;
        state->members.erase(existing);
        return true;
    }

    CohortHandle CohortStore::find_cohort(AgentHandle agent) const
    {
        for (std::size_t index = 1; index < slots.size(); ++index)
        {
            if (!slots[index].occupied)
                continue;
            const std::vector<AgentHandle> &members = slots[index].state.members;
            if (std::find(members.begin(), members.end(), agent) != members.end())
                return slots[index].state.handle;
        }
        return {};
    }

    void CohortStore::clear_flow(FlowHandle flow)
    {
        for (std::size_t index = 1; index < slots.size(); ++index)
        {
            if (slots[index].occupied && slots[index].state.flow_handle == flow)
                slots[index].state.flow_handle = {};
        }
    }

    std::size_t CohortStore::size() const
    {
        return static_cast<std::size_t>(std::count_if(
            slots.begin(), slots.end(), [](const Slot &slot) { return slot.occupied; }));
    }
} // namespace ffcore
