#include "flow_field_store.h"

#include <algorithm>

namespace ffcore
{
    FlowHandle FlowFieldStore::create_pending(
        const Vec2i &goal,
        std::uint64_t topology_revision,
        std::uint64_t cost_revision)
    {
        std::uint32_t index = 1;
        while (index < slots.size() && slots[index].occupied)
            ++index;
        if (index == slots.size())
            slots.push_back({});

        Slot &slot = slots[index];
        slot.occupied = true;
        slot.flow = StoredFlow();
        slot.flow.handle = {index, slot.generation};
        slot.flow.goal = goal;
        slot.flow.topology_revision = topology_revision;
        slot.flow.cost_revision = cost_revision;
        return slot.flow.handle;
    }

    bool FlowFieldStore::store(
        FlowHandle handle,
        const FlowField &field,
        std::uint64_t topology_revision,
        std::uint64_t cost_revision)
    {
        StoredFlow *stored = get(handle);
        if (stored == nullptr)
            return false;
        stored->field.copy_from(field);
        stored->topology_revision = topology_revision;
        stored->cost_revision = cost_revision;
        stored->status = field.is_ready() ? FlowStatus::Ready : FlowStatus::Unreachable;
        return true;
    }

    bool FlowFieldStore::set_status(FlowHandle handle, FlowStatus status)
    {
        StoredFlow *stored = get(handle);
        if (stored == nullptr)
            return false;
        stored->status = status;
        if (status != FlowStatus::Ready)
            stored->field.clear();
        return true;
    }

    bool FlowFieldStore::release(FlowHandle handle)
    {
        if (get(handle) == nullptr)
            return false;
        Slot &slot = slots[handle.index];
        slot.occupied = false;
        slot.flow = StoredFlow();
        ++slot.generation;
        if (slot.generation == 0)
            slot.generation = 1;
        return true;
    }

    StoredFlow *FlowFieldStore::get(FlowHandle handle)
    {
        if (handle.index >= slots.size())
            return nullptr;
        Slot &slot = slots[handle.index];
        return slot.occupied && slot.generation == handle.generation ? &slot.flow : nullptr;
    }

    const StoredFlow *FlowFieldStore::get(FlowHandle handle) const
    {
        if (handle.index >= slots.size())
            return nullptr;
        const Slot &slot = slots[handle.index];
        return slot.occupied && slot.generation == handle.generation ? &slot.flow : nullptr;
    }

    void FlowFieldStore::mark_stale()
    {
        for (std::size_t index = 1; index < slots.size(); ++index)
        {
            if (!slots[index].occupied)
                continue;
            if (slots[index].flow.status == FlowStatus::Cancelled)
                continue;
            slots[index].flow.status = FlowStatus::Stale;
            slots[index].flow.field.clear();
        }
    }

    std::vector<FlowHandle> FlowFieldStore::active_handles() const
    {
        std::vector<FlowHandle> handles;
        handles.reserve(size());
        for (std::size_t index = 1; index < slots.size(); ++index)
        {
            if (slots[index].occupied)
                handles.push_back(slots[index].flow.handle);
        }
        return handles;
    }

    std::size_t FlowFieldStore::size() const
    {
        return static_cast<std::size_t>(std::count_if(
            slots.begin(), slots.end(), [](const Slot &slot) { return slot.occupied; }));
    }
} // namespace ffcore
