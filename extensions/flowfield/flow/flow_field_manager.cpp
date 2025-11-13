#include "flow_field_manager.h"

namespace ffcore
{
    FlowFieldManager::FlowFieldManager()
    {
        fields.resize(MAX_FLOWFIELDS, nullptr);
    }

    FlowFieldID FlowFieldManager::create()
    {
        for (FlowFieldID i = 1; i < fields.size(); i++)
        {
            if (fields[i] == nullptr)
            {
                fields[i] = new FlowField();
                return i;
            }
        }
        return INVALID_FLOWFIELD;
    }

    FlowField* FlowFieldManager::get(FlowFieldID id)
    {
        if (id == INVALID_FLOWFIELD || id >= fields.size()) return nullptr;
        return fields[id];
    }

    void FlowFieldManager::remove(FlowFieldID id)
    {
        if (id == INVALID_FLOWFIELD || id >= fields.size()) return;
        delete fields[id];
        fields[id] = nullptr;
    }
}
