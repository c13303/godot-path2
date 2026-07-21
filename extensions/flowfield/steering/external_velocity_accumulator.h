#pragma once

#include "../core/types.h"
#include <unordered_map>

namespace ffcore
{
    // Generic movement contributed by environmental sources such as wind, water
    // currents or conveyors. Each source approaches its requested velocity smoothly
    // and releases smoothly when it expires, without taking ownership of navigation
    // or the smash/knockback velocity slot.
    class ExternalVelocityAccumulator
    {
    public:
        void refresh_source(int source_id, const Vec2 &target_velocity, double response_seconds, double expiry_seconds);
        void release_source(int source_id);
        void clear();
        void update(double delta);

        const Vec2 &current_velocity() const { return combined_velocity; }
        bool empty() const { return sources.empty(); }

    private:
        struct Source
        {
            Vec2 target_velocity;
            Vec2 current_velocity;
            double response_seconds = 0.0;
            double expiry_seconds = 0.0;
        };

        std::unordered_map<int, Source> sources;
        Vec2 combined_velocity;
    };
} // namespace ffcore
