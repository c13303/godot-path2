#include "directional_motion_field_store.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace ffcore
{
    DirectionalMotionSample DirectionalMotionField::sample(const Vec2 &world_position) const
    {
        DirectionalMotionSample result;
        if (cell_size <= 0.0 || speed <= 0.0 || directions.empty())
            return result;
        result.sample_position = world_position + sample_offset;
        const Vec2 local = (result.sample_position - world_origin) / cell_size;
        result.sample_cell = {
            static_cast<int>(std::floor(local.x)), static_cast<int>(std::floor(local.y))};
        const auto exact = directions.find(result.sample_cell);
        if (exact != directions.end())
        {
            result.found = true;
            result.exact = true;
            result.velocity = exact->second.normalized() * speed;
            return result;
        }
        if (fallback_radius <= 0.0)
            return result;

        const int radius_cells = static_cast<int>(std::ceil(fallback_radius / cell_size));
        const double radius_squared = fallback_radius * fallback_radius;
        double best_squared = std::numeric_limits<double>::infinity();
        for (int y = -radius_cells; y <= radius_cells; ++y)
        {
            for (int x = -radius_cells; x <= radius_cells; ++x)
            {
                const Vec2i cell(result.sample_cell.x + x, result.sample_cell.y + y);
                const auto direction = directions.find(cell);
                if (direction == directions.end())
                    continue;
                const Vec2 center = world_origin +
                    Vec2((cell.x + 0.5) * cell_size, (cell.y + 0.5) * cell_size);
                const double distance_squared =
                    (center - result.sample_position).length_squared();
                if (distance_squared > radius_squared || distance_squared >= best_squared)
                    continue;
                best_squared = distance_squared;
                result.velocity = direction->second.normalized() * speed;
            }
        }
        result.found = !result.velocity.is_zero();
        return result;
    }

    DirectionalMotionFieldHandle DirectionalMotionFieldStore::create(
        const DirectionalMotionField &field)
    {
        if (field.directions.empty() || !std::isfinite(field.cell_size) || field.cell_size <= 0.0 ||
            !std::isfinite(field.speed) || field.speed <= 0.0)
            return {};
        std::uint32_t index = 1;
        while (index < slots.size() && slots[index].occupied)
            ++index;
        if (index == slots.size())
            slots.push_back({});
        slots[index].occupied = true;
        slots[index].field = field;
        return {index, slots[index].generation};
    }

    bool DirectionalMotionFieldStore::update(
        DirectionalMotionFieldHandle handle, const DirectionalMotionField &field)
    {
        if (get(handle) == nullptr || field.directions.empty() ||
            !std::isfinite(field.cell_size) || field.cell_size <= 0.0 ||
            !std::isfinite(field.speed) || field.speed <= 0.0)
            return false;
        slots[handle.index].field = field;
        return true;
    }

    bool DirectionalMotionFieldStore::remove(DirectionalMotionFieldHandle handle)
    {
        if (get(handle) == nullptr)
            return false;
        Slot &slot = slots[handle.index];
        slot.occupied = false;
        slot.field = {};
        ++slot.generation;
        if (slot.generation == 0)
            slot.generation = 1;
        return true;
    }

    void DirectionalMotionFieldStore::clear()
    {
        for (DirectionalMotionFieldHandle handle : active_handles())
            remove(handle);
    }

    const DirectionalMotionField *DirectionalMotionFieldStore::get(
        DirectionalMotionFieldHandle handle) const
    {
        if (handle.index >= slots.size())
            return nullptr;
        const Slot &slot = slots[handle.index];
        return slot.occupied && slot.generation == handle.generation ? &slot.field : nullptr;
    }

    std::vector<DirectionalMotionFieldHandle> DirectionalMotionFieldStore::active_handles() const
    {
        std::vector<DirectionalMotionFieldHandle> handles;
        handles.reserve(size());
        for (std::size_t index = 1; index < slots.size(); ++index)
        {
            if (slots[index].occupied)
                handles.push_back({static_cast<std::uint32_t>(index), slots[index].generation});
        }
        return handles;
    }

    std::size_t DirectionalMotionFieldStore::size() const
    {
        return static_cast<std::size_t>(std::count_if(
            slots.begin(), slots.end(), [](const Slot &slot) { return slot.occupied; }));
    }
} // namespace ffcore
