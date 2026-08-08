#include "nav_services.h"

namespace ffcore
{
    static FlowFieldManager manager;

    FlowFieldManager* flowfields()
    {
        return &manager;
    }
}
