#include "external_velocity_source_store.h"

#include <algorithm>

namespace ffcore
{
    ExternalVelocitySourceHandle ExternalVelocitySourceStore::create()
    {
        std::uint32_t index = 1;
        while (index < slots.size() && slots[index].occupied)
            ++index;
        if (index == slots.size())
            slots.push_back({});
        slots[index].occupied = true;
        return {index, slots[index].generation};
    }

    bool ExternalVelocitySourceStore::remove(ExternalVelocitySourceHandle handle)
    {
        if (!contains(handle))
            return false;
        Slot &slot = slots[handle.index];
        slot.occupied = false;
        ++slot.generation;
        if (slot.generation == 0)
            slot.generation = 1;
        return true;
    }

    bool ExternalVelocitySourceStore::contains(ExternalVelocitySourceHandle handle) const
    {
        return handle.index < slots.size() && slots[handle.index].occupied &&
            slots[handle.index].generation == handle.generation;
    }

    std::size_t ExternalVelocitySourceStore::size() const
    {
        return static_cast<std::size_t>(std::count_if(
            slots.begin(), slots.end(), [](const Slot &slot) { return slot.occupied; }));
    }

    std::uint64_t encode_external_velocity_source(ExternalVelocitySourceHandle handle)
    {
        return (static_cast<std::uint64_t>(handle.generation) << 32) | handle.index;
    }
} // namespace ffcore
