#include "bottleneck_traffic_controller.h"

#include <algorithm>
#include <cmath>

namespace ffcore
{
    void BottleneckTrafficController::grant_waiting(Channel &channel)
    {
        std::size_t granted_count = 0;
        bool has_direction = false;
        TrafficDirection active_direction = TrafficDirection::Forward;
        for (const Reservation &reservation : channel.reservations)
        {
            if (!reservation.granted)
                continue;
            ++granted_count;
            active_direction = reservation.direction;
            has_direction = true;
        }
        if (granted_count >= channel.config.capacity)
            return;

        const TrafficDirection preferred = has_direction
            ? active_direction
            : (channel.last_completed_direction == TrafficDirection::Forward
                   ? TrafficDirection::Reverse
                   : TrafficDirection::Forward);
        std::vector<Reservation *> waiting;
        for (Reservation &reservation : channel.reservations)
        {
            if (!reservation.granted && (!has_direction || reservation.direction == active_direction))
                waiting.push_back(&reservation);
        }
        std::sort(waiting.begin(), waiting.end(),
                  [preferred](const Reservation *left, const Reservation *right)
                  {
                      if (left->priority != right->priority)
                          return left->priority > right->priority;
                      const bool left_preferred = left->direction == preferred;
                      const bool right_preferred = right->direction == preferred;
                      if (left_preferred != right_preferred)
                          return left_preferred;
                      return left->sequence < right->sequence;
                  });
        for (Reservation *reservation : waiting)
        {
            if (granted_count >= channel.config.capacity)
                break;
            if (has_direction && reservation->direction != active_direction)
                continue;
            reservation->granted = true;
            active_direction = reservation->direction;
            has_direction = true;
            ++granted_count;
        }
    }

    void BottleneckTrafficController::configure(
        std::uint64_t bottleneck_id,
        const BottleneckTrafficConfig &config)
    {
        Channel &channel = channels[bottleneck_id];
        channel.config.capacity = std::max<std::uint32_t>(1, config.capacity);
        channel.config.reservation_timeout =
            std::isfinite(config.reservation_timeout) ? std::max(0.001, config.reservation_timeout) : 2.0;
        grant_waiting(channel);
    }

    bool BottleneckTrafficController::request(
        std::uint64_t bottleneck_id,
        std::uint64_t agent_id,
        TrafficDirection direction,
        int priority)
    {
        Channel &channel = channels[bottleneck_id];
        if (channel.config.capacity == 0)
            channel.config.capacity = 1;
        for (Reservation &reservation : channel.reservations)
        {
            if (reservation.agent != agent_id)
                continue;
            reservation.direction = direction;
            reservation.priority = priority;
            reservation.remaining = channel.config.reservation_timeout;
            grant_waiting(channel);
            return reservation.granted;
        }
        channel.reservations.push_back({
            agent_id, direction, priority, next_sequence++, channel.config.reservation_timeout, false});
        grant_waiting(channel);
        return channel.reservations.back().granted;
    }

    bool BottleneckTrafficController::is_granted(
        std::uint64_t bottleneck_id,
        std::uint64_t agent_id) const
    {
        const auto channel = channels.find(bottleneck_id);
        if (channel == channels.end())
            return false;
        for (const Reservation &reservation : channel->second.reservations)
        {
            if (reservation.agent == agent_id)
                return reservation.granted;
        }
        return false;
    }

    void BottleneckTrafficController::release(
        std::uint64_t bottleneck_id,
        std::uint64_t agent_id)
    {
        auto channel = channels.find(bottleneck_id);
        if (channel == channels.end())
            return;
        auto &reservations = channel->second.reservations;
        for (const Reservation &reservation : reservations)
        {
            if (reservation.agent == agent_id && reservation.granted)
                channel->second.last_completed_direction = reservation.direction;
        }
        reservations.erase(
            std::remove_if(reservations.begin(), reservations.end(),
                           [agent_id](const Reservation &reservation)
                           { return reservation.agent == agent_id; }),
            reservations.end());
        grant_waiting(channel->second);
    }

    void BottleneckTrafficController::remove_agent(std::uint64_t agent_id)
    {
        for (auto &entry : channels)
            release(entry.first, agent_id);
    }

    void BottleneckTrafficController::update(double delta)
    {
        if (!std::isfinite(delta) || delta <= 0.0)
            return;
        for (auto &entry : channels)
        {
            Channel &channel = entry.second;
            for (Reservation &reservation : channel.reservations)
            {
                if (reservation.granted)
                {
                    reservation.remaining -= delta;
                    if (reservation.remaining <= 0.0)
                        channel.last_completed_direction = reservation.direction;
                }
            }
            channel.reservations.erase(
                std::remove_if(channel.reservations.begin(), channel.reservations.end(),
                               [](const Reservation &reservation)
                               { return reservation.granted && reservation.remaining <= 0.0; }),
                channel.reservations.end());
            grant_waiting(channel);
        }
    }

    std::size_t BottleneckTrafficController::occupancy(std::uint64_t bottleneck_id) const
    {
        const auto channel = channels.find(bottleneck_id);
        if (channel == channels.end())
            return 0;
        return static_cast<std::size_t>(std::count_if(
            channel->second.reservations.begin(), channel->second.reservations.end(),
            [](const Reservation &reservation) { return reservation.granted; }));
    }

    std::size_t BottleneckTrafficController::waiting_count(std::uint64_t bottleneck_id) const
    {
        const auto channel = channels.find(bottleneck_id);
        if (channel == channels.end())
            return 0;
        return static_cast<std::size_t>(std::count_if(
            channel->second.reservations.begin(), channel->second.reservations.end(),
            [](const Reservation &reservation) { return !reservation.granted; }));
    }
} // namespace ffcore
