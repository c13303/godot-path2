#include "steering_system.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>

using namespace ffcore;

namespace
{
    Vec2 normalized_or_zero(const Vec2 &v)
    {
        if (!std::isfinite(v.x) || !std::isfinite(v.y))
            return Vec2(0, 0);
        const double len = v.length();
        if (!std::isfinite(len) || len < 1e-6)
            return Vec2(0, 0);
        return v * (1.0 / len);
    }
}

void SteeringSystem::set_directional_cell_field(int field_id,
                                                const Vec2 &origin_world,
                                                double tile_size,
                                                double speed,
                                                const std::vector<Vec2i> &cells,
                                                const std::vector<Vec2> &directions,
                                                const Vec2 &sample_offset_world,
                                                double sample_radius_world)
{
    if (field_id < 0)
        return;
    const std::size_t count = std::min(cells.size(), directions.size());
    if (count == 0 || speed <= 0.0 || !std::isfinite(speed))
    {
        clear_directional_cell_field(field_id);
        return;
    }

    DirectionalCellField field;
    field.origin_world = origin_world;
    field.sample_offset_world = sample_offset_world;
    field.tile_size = std::max(1.0, std::isfinite(tile_size) ? tile_size : 32.0);
    field.speed = speed;
    field.sample_radius_world = std::max(0.0, std::isfinite(sample_radius_world) ? sample_radius_world : 0.0);
    field.directions.reserve(count);
    for (std::size_t i = 0; i < count; ++i)
    {
        Vec2 dir = normalized_or_zero(directions[i]);
        if (dir.is_zero())
            continue;
        field.directions[field.key(cells[i].x, cells[i].y)] = dir;
    }

    if (field.directions.empty())
        clear_directional_cell_field(field_id);
    else
        directional_cell_fields[field_id] = std::move(field);
}

void SteeringSystem::clear_directional_cell_field(int field_id)
{
    directional_cell_fields.erase(field_id);
    for (auto it = phase_directional_cell_fields.begin(); it != phase_directional_cell_fields.end();)
    {
        if (it->second == field_id)
            it = phase_directional_cell_fields.erase(it);
        else
            ++it;
    }
}

void SteeringSystem::clear_directional_cell_fields()
{
    directional_cell_fields.clear();
    phase_directional_cell_fields.clear();
}

void SteeringSystem::bind_phase_directional_cell_field(AgentPhase phase, int field_id)
{
    if (field_id < 0 || directional_cell_fields.find(field_id) == directional_cell_fields.end())
    {
        clear_phase_directional_cell_field(phase);
        return;
    }
    phase_directional_cell_fields[(int)phase] = field_id;
}

void SteeringSystem::clear_phase_directional_cell_field(AgentPhase phase)
{
    phase_directional_cell_fields.erase((int)phase);
}

DirectionalCellFieldSample SteeringSystem::directional_cell_field_sample_for_agent(const AgentData &agent) const
{
    DirectionalCellFieldSample sample;
    auto phase_it = phase_directional_cell_fields.find((int)agent.phase);
    if (phase_it == phase_directional_cell_fields.end())
        return sample;
    sample.phase_bound = true;
    sample.field_id = phase_it->second;

    auto field_it = directional_cell_fields.find(phase_it->second);
    if (field_it == directional_cell_fields.end())
        return sample;
    sample.field_found = true;

    const DirectionalCellField &field = field_it->second;
    const Vec2 sample_world = agent.position + field.sample_offset_world;
    const Vec2i cell = field.world_to_cell(sample_world);
    sample.sample_world = sample_world;
    sample.sample_cell = cell;

    auto exact_it = field.directions.find(field.key(cell.x, cell.y));
    if (exact_it != field.directions.end()) {
        sample.exact = true;
        sample.velocity = exact_it->second * field.speed;
        return sample;
    }

    if (field.sample_radius_world <= 0.0)
        return sample;

    const int radius_cells = (int)std::ceil(field.sample_radius_world / std::max(1.0, field.tile_size));
    const double radius_sq = field.sample_radius_world * field.sample_radius_world;
    double best_sq = std::numeric_limits<double>::infinity();
    Vec2 best_dir(0, 0);
    for (int dy = -radius_cells; dy <= radius_cells; ++dy)
    {
        for (int dx = -radius_cells; dx <= radius_cells; ++dx)
        {
            const Vec2i candidate(cell.x + dx, cell.y + dy);
            auto dir_it = field.directions.find(field.key(candidate.x, candidate.y));
            if (dir_it == field.directions.end())
                continue;
            const Vec2 candidate_center = field.origin_world + Vec2((candidate.x + 0.5) * field.tile_size, (candidate.y + 0.5) * field.tile_size);
            const double dist_sq = (candidate_center - sample_world).length_squared();
            if (dist_sq > radius_sq || dist_sq >= best_sq)
                continue;
            best_sq = dist_sq;
            best_dir = dir_it->second;
        }
    }

    if (!best_dir.is_zero()) {
        sample.fallback = true;
        sample.velocity = best_dir * field.speed;
    }
    return sample;
}

Vec2 SteeringSystem::directional_cell_field_velocity_for_agent(const AgentData &agent) const
{
    return directional_cell_field_sample_for_agent(agent).velocity;
}
