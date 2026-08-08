#include "static_obstacle_store.h"

#include <algorithm>
#include <cmath>

namespace ffcore
{
    namespace
    {
        double sanitized_radius(double radius)
        {
            return std::isfinite(radius) && radius > 0.0 ? radius : 0.001;
        }

        double sanitized_strength(double strength)
        {
            return std::isfinite(strength) && strength >= 0.0 ? strength : 1.0;
        }
    }

    StaticObstacleHandle StaticObstacleStore::create(
        const Vec2 &position, double radius, double push_strength)
    {
        if (!std::isfinite(position.x) || !std::isfinite(position.y))
            return {};
        std::uint32_t index = 1;
        while (index < slots.size() && slots[index].occupied)
            ++index;
        if (index == slots.size())
            slots.push_back({});
        Slot &slot = slots[index];
        slot.occupied = true;
        slot.obstacle = {
            {index, slot.generation}, position,
            sanitized_radius(radius), sanitized_strength(push_strength)};
        spatial.insert(static_cast<int>(index), position);
        maximum_radius = std::max(maximum_radius, slot.obstacle.radius);
        return slot.obstacle.handle;
    }

    bool StaticObstacleStore::update(
        StaticObstacleHandle handle, const Vec2 &position,
        double radius, double push_strength)
    {
        if (!std::isfinite(position.x) || !std::isfinite(position.y))
            return false;
        Slot *slot = handle.index < slots.size() ? &slots[handle.index] : nullptr;
        if (slot == nullptr || !slot->occupied || slot->generation != handle.generation)
            return false;
        const Vec2 old_position = slot->obstacle.position;
        slot->obstacle.position = position;
        slot->obstacle.radius = sanitized_radius(radius);
        slot->obstacle.push_strength = sanitized_strength(push_strength);
        spatial.update(static_cast<int>(handle.index), old_position, position);
        recompute_maximum_radius();
        return true;
    }

    bool StaticObstacleStore::remove(StaticObstacleHandle handle)
    {
        if (get(handle) == nullptr)
            return false;
        Slot &slot = slots[handle.index];
        spatial.remove(static_cast<int>(handle.index));
        slot.occupied = false;
        slot.obstacle = {};
        ++slot.generation;
        if (slot.generation == 0)
            slot.generation = 1;
        recompute_maximum_radius();
        return true;
    }

    void StaticObstacleStore::clear()
    {
        const std::vector<StaticObstacleHandle> handles = active_handles();
        for (StaticObstacleHandle handle : handles)
            remove(handle);
    }

    const StaticObstacle *StaticObstacleStore::get(StaticObstacleHandle handle) const
    {
        if (handle.index >= slots.size())
            return nullptr;
        const Slot &slot = slots[handle.index];
        return slot.occupied && slot.generation == handle.generation
            ? &slot.obstacle : nullptr;
    }

    std::vector<StaticObstacleHandle> StaticObstacleStore::query(
        const Vec2 &position, double radius) const
    {
        std::vector<StaticObstacleHandle> result;
        for (int index : spatial.query_neighbors(position, std::max(0.0, radius)))
        {
            if (index <= 0 || static_cast<std::size_t>(index) >= slots.size())
                continue;
            const Slot &slot = slots[static_cast<std::size_t>(index)];
            if (slot.occupied)
                result.push_back(slot.obstacle.handle);
        }
        return result;
    }

    std::vector<StaticObstacleHandle> StaticObstacleStore::active_handles() const
    {
        std::vector<StaticObstacleHandle> handles;
        handles.reserve(size());
        for (std::size_t index = 1; index < slots.size(); ++index)
        {
            if (slots[index].occupied)
                handles.push_back(slots[index].obstacle.handle);
        }
        return handles;
    }

    void StaticObstacleStore::recompute_maximum_radius()
    {
        maximum_radius = 0.0;
        for (std::size_t index = 1; index < slots.size(); ++index)
        {
            if (slots[index].occupied)
                maximum_radius = std::max(maximum_radius, slots[index].obstacle.radius);
        }
    }

    std::size_t StaticObstacleStore::size() const
    {
        return static_cast<std::size_t>(std::count_if(
            slots.begin(), slots.end(), [](const Slot &slot) { return slot.occupied; }));
    }
} // namespace ffcore
