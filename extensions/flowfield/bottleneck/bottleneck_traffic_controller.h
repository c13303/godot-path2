#pragma once

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace ffcore
{
    enum class TrafficDirection
    {
        Forward = 1,
        Reverse = -1
    };

    struct BottleneckTrafficConfig
    {
        std::uint32_t capacity = 1;
        double reservation_timeout = 2.0;
    };

    class BottleneckTrafficController
    {
    private:
        struct Reservation
        {
            std::uint64_t agent = 0;
            TrafficDirection direction = TrafficDirection::Forward;
            int priority = 0;
            std::uint64_t sequence = 0;
            double remaining = 0.0;
            bool granted = false;
        };

        struct Channel
        {
            BottleneckTrafficConfig config;
            std::vector<Reservation> reservations;
            TrafficDirection last_completed_direction = TrafficDirection::Reverse;
        };

        std::unordered_map<std::uint64_t, Channel> channels;
        std::uint64_t next_sequence = 1;

        static void grant_waiting(Channel &channel);

    public:
        void configure(std::uint64_t bottleneck_id, const BottleneckTrafficConfig &config);
        bool request(std::uint64_t bottleneck_id, std::uint64_t agent_id,
                     TrafficDirection direction, int priority = 0);
        bool is_granted(std::uint64_t bottleneck_id, std::uint64_t agent_id) const;
        void release(std::uint64_t bottleneck_id, std::uint64_t agent_id);
        void remove_agent(std::uint64_t agent_id);
        void update(double delta);
        std::size_t occupancy(std::uint64_t bottleneck_id) const;
        std::size_t waiting_count(std::uint64_t bottleneck_id) const;
    };
} // namespace ffcore
