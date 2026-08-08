#pragma once

#include "../core/types.h"

#include <cstdint>
#include <limits>
#include <vector>

namespace ffcore
{
    struct ProfileHandle
    {
        std::uint32_t index = 0;
        std::uint32_t generation = 0;

        bool is_valid() const { return index != 0; }
        bool operator==(const ProfileHandle &other) const
        { return index == other.index && generation == other.generation; }
    };

    struct CrowdAgentProfile
    {
        double radius = 8.0;
        Vec2 collision_offset;
        double maximum_speed = 80.0;
        double acceleration = 400.0;
        double deceleration = 500.0;
        double separation_radius = 20.0;
        double separation_weight = 1.0;
        double arrival_radius = 4.0;
        int terrain_speed_channel = 0;
        std::uint32_t category_mask = std::numeric_limits<std::uint32_t>::max();
        double contact_push_strength = 0.0;
        double contact_push_resistance = 1.0;
        double contact_push_cooldown = 0.2;
        double contact_impulse_decay = 0.65;
        double contact_control_suppression = 0.2;
    };

    class CrowdProfileStore
    {
    private:
        struct Slot
        {
            std::uint32_t generation = 1;
            bool occupied = false;
            CrowdAgentProfile profile;
        };

        std::vector<Slot> slots = std::vector<Slot>(1);

    public:
        static CrowdAgentProfile sanitize(const CrowdAgentProfile &profile);
        ProfileHandle create(const CrowdAgentProfile &profile);
        bool update(ProfileHandle handle, const CrowdAgentProfile &profile);
        bool remove(ProfileHandle handle);
        const CrowdAgentProfile *get(ProfileHandle handle) const;
        std::size_t size() const;
    };
} // namespace ffcore
