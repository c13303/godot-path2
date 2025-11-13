#pragma once
#include <cstdint>

namespace ffcore
{
    using FlowFieldID = std::uint32_t;
    using GroupID = std::uint32_t;

    constexpr FlowFieldID INVALID_FLOWFIELD = 0;
    constexpr GroupID INVALID_GROUP = 0;
}
