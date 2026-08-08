#pragma once

#include <cstdint>
#include <vector>

namespace ffcore
{
    struct ExternalVelocitySourceHandle
    {
        std::uint32_t index = 0;
        std::uint32_t generation = 0;
        bool is_valid() const { return index != 0; }
        bool operator==(const ExternalVelocitySourceHandle &other) const
        { return index == other.index && generation == other.generation; }
    };

    class ExternalVelocitySourceStore
    {
    private:
        struct Slot
        {
            std::uint32_t generation = 1;
            bool occupied = false;
        };
        std::vector<Slot> slots = std::vector<Slot>(1);

    public:
        ExternalVelocitySourceHandle create();
        bool remove(ExternalVelocitySourceHandle handle);
        bool contains(ExternalVelocitySourceHandle handle) const;
        std::size_t size() const;
    };

    std::uint64_t encode_external_velocity_source(ExternalVelocitySourceHandle handle);
} // namespace ffcore
