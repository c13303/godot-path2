#pragma once

#include "../core/types.h"
#include "../flow/flow_field_algorithms.h"

#include <cstdint>
#include <vector>

namespace ffcore
{
    struct DirectionalMotionFieldHandle
    {
        std::uint32_t index = 0;
        std::uint32_t generation = 0;
        bool is_valid() const { return index != 0; }
        bool operator==(const DirectionalMotionFieldHandle &other) const
        { return index == other.index && generation == other.generation; }
    };

    struct DirectionalMotionSample
    {
        bool found = false;
        bool exact = false;
        Vec2 sample_position;
        Vec2i sample_cell;
        Vec2 velocity;
    };

    struct DirectionalMotionField
    {
        Vec2 world_origin;
        Vec2 sample_offset;
        double cell_size = 32.0;
        double speed = 0.0;
        double fallback_radius = 0.0;
        std::unordered_map<Vec2i, Vec2, CellHash> directions;

        DirectionalMotionSample sample(const Vec2 &world_position) const;
    };

    class DirectionalMotionFieldStore
    {
    private:
        struct Slot
        {
            std::uint32_t generation = 1;
            bool occupied = false;
            DirectionalMotionField field;
        };
        std::vector<Slot> slots = std::vector<Slot>(1);

    public:
        DirectionalMotionFieldHandle create(const DirectionalMotionField &field);
        bool update(DirectionalMotionFieldHandle handle, const DirectionalMotionField &field);
        bool remove(DirectionalMotionFieldHandle handle);
        void clear();
        const DirectionalMotionField *get(DirectionalMotionFieldHandle handle) const;
        std::vector<DirectionalMotionFieldHandle> active_handles() const;
        std::size_t size() const;
    };
} // namespace ffcore
