#pragma once
#include <vector>
#include "../core/nav_types.h"
#include "../core/nav_config.h"
#include "flow_field.h"

namespace ffcore
{
    class FlowFieldManager
    {
    public:
        FlowFieldManager();

        FlowFieldID create();
        FlowField* get(FlowFieldID id);
        void remove(FlowFieldID id);

    private:
        std::vector<FlowField*> fields;
    };
}
