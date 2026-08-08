#include "external_velocity_accumulator.h"

#include <algorithm>
#include <cmath>

namespace ffcore
{
namespace
{
    constexpr double RELEASE_CUTOFF_SPEED = 0.05;
}

void ExternalVelocityAccumulator::refresh_source(std::uint64_t source_id, const Vec2 &target_velocity, double response_seconds, double expiry_seconds)
{
    if (source_id == 0 || !std::isfinite(target_velocity.x) || !std::isfinite(target_velocity.y))
        return;

    Source &source = sources[source_id];
    source.target_velocity = target_velocity;
    source.response_seconds = std::max(0.0, response_seconds);
    source.expiry_seconds = std::max(0.0, expiry_seconds);
}

void ExternalVelocityAccumulator::release_source(std::uint64_t source_id)
{
    auto it = sources.find(source_id);
    if (it == sources.end())
        return;

    it->second.target_velocity = Vec2(0, 0);
    it->second.expiry_seconds = 0.0;
}

void ExternalVelocityAccumulator::clear()
{
    sources.clear();
    combined_velocity = Vec2(0, 0);
}

void ExternalVelocityAccumulator::update(double delta)
{
    const double safe_delta = std::max(0.0, delta);
    combined_velocity = Vec2(0, 0);

    for (auto it = sources.begin(); it != sources.end();)
    {
        Source &source = it->second;
        source.expiry_seconds = std::max(0.0, source.expiry_seconds - safe_delta);
        if (source.expiry_seconds <= 0.0)
            source.target_velocity = Vec2(0, 0);

        const double blend = source.response_seconds <= 0.000001
                                 ? 1.0
                                 : 1.0 - std::exp(-safe_delta / source.response_seconds);
        source.current_velocity = source.current_velocity + (source.target_velocity - source.current_velocity) * blend;

        if (source.expiry_seconds <= 0.0 && source.current_velocity.length_squared() <= RELEASE_CUTOFF_SPEED * RELEASE_CUTOFF_SPEED)
        {
            it = sources.erase(it);
            continue;
        }

        combined_velocity = combined_velocity + source.current_velocity;
        ++it;
    }
}
} // namespace ffcore
