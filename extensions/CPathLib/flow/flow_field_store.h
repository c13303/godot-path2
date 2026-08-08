#pragma once

#include "flow_field.h"

#include <cstdint>
#include <vector>

namespace ffcore
{
    struct FlowHandle
    {
        std::uint32_t index = 0;
        std::uint32_t generation = 0;

        bool is_valid() const { return index != 0; }
        bool operator==(const FlowHandle &other) const
        { return index == other.index && generation == other.generation; }
        bool operator!=(const FlowHandle &other) const { return !(*this == other); }
    };

    enum class FlowStatus
    {
        Pending,
        Ready,
        Unreachable,
        Stale,
        Cancelled
    };

    struct StoredFlow
    {
        FlowHandle handle;
        FlowStatus status = FlowStatus::Pending;
        Vec2i goal;
        std::uint64_t topology_revision = 0;
        std::uint64_t cost_revision = 0;
        FlowField field;
    };

    class FlowFieldStore
    {
    private:
        struct Slot
        {
            std::uint32_t generation = 1;
            bool occupied = false;
            StoredFlow flow;
        };

        std::vector<Slot> slots = std::vector<Slot>(1);

    public:
        FlowHandle create_pending(const Vec2i &goal,
                                  std::uint64_t topology_revision,
                                  std::uint64_t cost_revision);
        bool store(FlowHandle handle, const FlowField &field,
                   std::uint64_t topology_revision, std::uint64_t cost_revision);
        bool set_status(FlowHandle handle, FlowStatus status);
        bool release(FlowHandle handle);
        StoredFlow *get(FlowHandle handle);
        const StoredFlow *get(FlowHandle handle) const;
        void mark_stale();
        std::vector<FlowHandle> active_handles() const;
        std::size_t size() const;
    };
} // namespace ffcore
