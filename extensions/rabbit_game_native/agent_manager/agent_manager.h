#pragma once
#include <vector>
#include <unordered_map>
#include "CPathLib/core/types.h"
#include "../core/nav_config.h"
namespace ffcore
{
    class FlowField;
    struct FormationFootprint
    {
        int w = 1;
        int h = 1;
        double angle = 0.0;
    };
}
namespace ffcore
{
    // Per-group flow-field compute state, used to freeze + label agents while their
    // routing field is not yet usable. NONE = field is current; QUEUED = GDScript has
    // enqueued a rebuild but not submitted it to the async worker yet; COMPUTING = the
    // request has been submitted and is being computed / not yet applied.
    enum GroupFlowWait
    {
        GROUP_FLOW_WAIT_NONE = 0,
        GROUP_FLOW_WAIT_QUEUED = 1,
        GROUP_FLOW_WAIT_COMPUTING = 2,
    };

    struct AgentGroup
    {
        GroupID id = INVALID_GROUP;
        bool active = false;
        FlowField *flow = nullptr;
        bool has_order = false;
        // See GroupFlowWait. Set by FlowFieldNative as a rebuild is queued/computed/applied.
        int flow_wait = GROUP_FLOW_WAIT_NONE;
        // Bumped every time this numeric group id starts or ends a lifecycle. Async
        // flow-field requests carry this so stale results from a dissolved/reused id
        // cannot install into the new group.
        std::uint64_t lifecycle_generation = 0;
    };

    struct AgentEntry
    {
        int id = -1;
        GroupID group = INVALID_GROUP;
        Vec2 position;
    };

    class AgentManager
    {
    public:
        AgentManager();
        GroupID create_group();
        void add_agent_to_group(int agent_id, GroupID group);
        void remove_agent(int id);
        AgentEntry *get(int id);
        const AgentEntry *get(int id) const;
        FlowField *get_group_flow(GroupID group) const;
        void set_group_flow(GroupID group, FlowField *flow);
        void set_group_flow_wait(GroupID group, int state);
        int get_group_flow_wait(GroupID group) const;
        std::uint64_t get_group_generation(GroupID group) const;
        void create_agent_entry(int agent_id, const Vec2 &pos, GroupID group);
        static const GroupID GROUP_IDLE = 0;
        void dissolve_group(GroupID group);
        ffcore::AgentGroup *get_groups() { return groups; }
        const ffcore::AgentGroup *get_groups() const { return groups; }
        bool is_group_active(GroupID g) const;
        bool all_agents_inactive(GroupID g) const;
        void mark_group_finished(GroupID g);
        void mark_group_has_order(GroupID g);
        int count_group_members(GroupID g) const;
        int count_groups_referencing_flow(const FlowField *flow) const;
        FormationFootprint compute_group_footprint(GroupID g) const;

        // Read-only debug introspection. Fills `out` with every currently
        // registered agent id (the keys of id_to_index), sorted ascending.
        // No state mutation, no cleanup. Used only by the debug registration
        // consistency watcher; nothing calls it on the hot path.
        void debug_collect_agent_ids(std::vector<int> &out) const;

    private:
        std::vector<AgentEntry> agents;
        std::unordered_map<int, int> id_to_index;
        AgentGroup groups[MAX_GROUPS];
    };

    AgentManager *get_global_agent_manager();
}
