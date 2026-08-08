#pragma once

#include "agent_world.h"

#include <cstdint>
#include <vector>

namespace ffcore
{
    struct CohortHandle
    {
        std::uint32_t index = 0;
        std::uint32_t generation = 0;

        bool is_valid() const { return index != 0; }
        bool operator==(const CohortHandle &other) const
        { return index == other.index && generation == other.generation; }
    };

    struct CohortState
    {
        CohortHandle handle;
        std::vector<AgentHandle> members;
        FlowHandle flow_handle;
    };

    class CohortStore
    {
    private:
        struct Slot
        {
            std::uint32_t generation = 1;
            bool occupied = false;
            CohortState state;
        };

        std::vector<Slot> slots = std::vector<Slot>(1);

    public:
        CohortHandle create();
        bool remove(CohortHandle handle);
        CohortState *get(CohortHandle handle);
        const CohortState *get(CohortHandle handle) const;
        bool add_member(CohortHandle cohort, AgentHandle agent);
        bool remove_member(CohortHandle cohort, AgentHandle agent);
        CohortHandle find_cohort(AgentHandle agent) const;
        void clear_flow(FlowHandle flow);
        std::size_t size() const;
    };
} // namespace ffcore
