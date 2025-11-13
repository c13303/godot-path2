#pragma once
#include "../core/nav_types.h"

namespace ffcore
{
    struct AgentGroup
    {
        GroupID id = INVALID_GROUP;
        FlowFieldID flow_id = INVALID_FLOWFIELD;
        bool active = false;
    };
}
