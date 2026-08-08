#include "crowd_profile_store.h"

#include <algorithm>
#include <cmath>

namespace ffcore
{
    CrowdAgentProfile CrowdProfileStore::sanitize(const CrowdAgentProfile &requested)
    {
        CrowdAgentProfile profile = requested;
        profile.radius = std::isfinite(profile.radius) ? std::max(0.0, profile.radius) : 8.0;
        profile.maximum_speed = std::isfinite(profile.maximum_speed) ? std::max(0.0, profile.maximum_speed) : 80.0;
        profile.acceleration = std::isfinite(profile.acceleration) ? std::max(0.0, profile.acceleration) : 400.0;
        profile.deceleration = std::isfinite(profile.deceleration) ? std::max(0.0, profile.deceleration) : 500.0;
        profile.separation_radius = std::isfinite(profile.separation_radius) ? std::max(0.0, profile.separation_radius) : 20.0;
        profile.separation_weight = std::isfinite(profile.separation_weight) ? std::max(0.0, profile.separation_weight) : 1.0;
        profile.arrival_radius = std::isfinite(profile.arrival_radius) ? std::max(0.0, profile.arrival_radius) : 4.0;
        return profile;
    }

    ProfileHandle CrowdProfileStore::create(const CrowdAgentProfile &profile)
    {
        std::uint32_t index = 1;
        while (index < slots.size() && slots[index].occupied)
            ++index;
        if (index == slots.size())
            slots.push_back({});
        Slot &slot = slots[index];
        slot.occupied = true;
        slot.profile = sanitize(profile);
        return {index, slot.generation};
    }

    bool CrowdProfileStore::update(ProfileHandle handle, const CrowdAgentProfile &profile)
    {
        if (get(handle) == nullptr)
            return false;
        slots[handle.index].profile = sanitize(profile);
        return true;
    }

    bool CrowdProfileStore::remove(ProfileHandle handle)
    {
        if (get(handle) == nullptr)
            return false;
        Slot &slot = slots[handle.index];
        slot.occupied = false;
        slot.profile = CrowdAgentProfile();
        ++slot.generation;
        if (slot.generation == 0)
            slot.generation = 1;
        return true;
    }

    const CrowdAgentProfile *CrowdProfileStore::get(ProfileHandle handle) const
    {
        if (handle.index >= slots.size())
            return nullptr;
        const Slot &slot = slots[handle.index];
        return slot.occupied && slot.generation == handle.generation ? &slot.profile : nullptr;
    }

    std::size_t CrowdProfileStore::size() const
    {
        return static_cast<std::size_t>(std::count_if(
            slots.begin(), slots.end(), [](const Slot &slot) { return slot.occupied; }));
    }
} // namespace ffcore
