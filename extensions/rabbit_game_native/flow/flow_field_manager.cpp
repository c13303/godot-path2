#include "flow_field_manager.h"
#include "../core/nav_services.h"
#include "../agent_manager/agent_manager.h"
#include <algorithm>

namespace ffcore
{
	FlowFieldManager::FlowFieldManager()
	{
		fields.resize(MAX_FLOWFIELDS, nullptr);
		refcounts.resize(MAX_FLOWFIELDS, 0);
		target_radii.resize(MAX_FLOWFIELDS, 0.0);
	}

	FlowFieldID FlowFieldManager::register_existing(FlowField *f)
	{
		if (!f)
			return INVALID_FLOWFIELD;

		for (FlowFieldID i = 1; i < MAX_FLOWFIELDS; i++)
		{
			if (fields[i] == nullptr)
			{
				fields[i] = f;
				refcounts[i] = 0;
				target_radii[i] = 0.0;
				return i;
			}
		}
		return INVALID_FLOWFIELD;
	}

	FlowField *FlowFieldManager::get(FlowFieldID id) const
	{
		if (id <= 0 || id >= MAX_FLOWFIELDS)
			return nullptr;
		return fields[id];
	}

	void FlowFieldManager::remove(FlowFieldID id)
	{
		if (id <= 0 || id >= MAX_FLOWFIELDS)
			return;
		delete fields[id];
		fields[id] = nullptr;
		refcounts[id] = 0;
		target_radii[id] = 0.0;
	}

	FlowFieldID FlowFieldManager::create_field(int width, int height, double tile_size)
	{
		FlowField *f = new FlowField(width, height, tile_size);
		FlowFieldID fid = register_existing(f);
		if (fid == INVALID_FLOWFIELD)
		{
			delete f;
			return INVALID_FLOWFIELD;
		}
		return fid;
	}

	FlowFieldID FlowFieldManager::register_copy(const FlowField &src)
	{
		FlowField *f = new FlowField(src.width(), src.height(), src.tile_size());
		f->copy_from(src);
		FlowFieldID fid = register_existing(f);
		if (fid == INVALID_FLOWFIELD)
		{
			delete f;
			return INVALID_FLOWFIELD;
		}
		return fid;
	}

	int FlowFieldManager::used_count() const
	{
		int count = 0;
		for (FlowFieldID i = 1; i < fields.size(); i++)
		{
			if (fields[i] != nullptr)
				++count;
		}
		return count;
	}

	int FlowFieldManager::capacity() const
	{
		return std::max(0, (int)fields.size() - 1);
	}

	void FlowFieldManager::collect_occupied_ids(std::vector<FlowFieldID> &out) const
	{
		out.clear();
		for (FlowFieldID i = 1; i < fields.size(); i++)
		{
			if (fields[i] != nullptr)
				out.push_back(i);
		}
	}

	FlowFieldID FlowFieldManager::id_for(const FlowField *field) const
	{
		if (!field)
			return INVALID_FLOWFIELD;
		for (FlowFieldID id = 1; id < fields.size(); ++id)
		{
			if (fields[id] == field)
				return id;
		}
		return INVALID_FLOWFIELD;
	}

	int FlowFieldManager::refcount(const FlowField *field) const
	{
		const FlowFieldID id = id_for(field);
		return id == INVALID_FLOWFIELD ? 0 : refcounts[id];
	}

	void FlowFieldManager::retain(FlowField *field)
	{
		const FlowFieldID id = id_for(field);
		if (id != INVALID_FLOWFIELD)
			++refcounts[id];
	}

	void FlowFieldManager::release(FlowField *field)
	{
		const FlowFieldID id = id_for(field);
		if (id != INVALID_FLOWFIELD && refcounts[id] > 0)
			--refcounts[id];
	}

	void FlowFieldManager::set_target_radius(FlowField *field, double radius)
	{
		const FlowFieldID id = id_for(field);
		if (id != INVALID_FLOWFIELD)
			target_radii[id] = std::max(0.0, radius);
	}

	double FlowFieldManager::target_radius(const FlowField *field) const
	{
		const FlowFieldID id = id_for(field);
		return id == INVALID_FLOWFIELD ? 0.0 : target_radii[id];
	}

	void cleanup_flow_if_unused(FlowField *ff)
	{
		if (!ff)
			return;

		auto *fm = flowfields();
		if (fm && fm->refcount(ff) <= 0 && fm->id_for(ff) != INVALID_FLOWFIELD)
		{
			if (auto *agent_manager = get_global_agent_manager())
			{
				for (GroupID group = 1; group < MAX_GROUPS; group++)
				{
					if (agent_manager->get_group_flow(group) == ff)
						return;
				}
			}

			fm->remove(fm->id_for(ff));
			/* godot::UtilityFunctions::print("FF DELTED"); */
		}
	}
}
