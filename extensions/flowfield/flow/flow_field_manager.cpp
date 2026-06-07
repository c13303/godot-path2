#include "flow_field_manager.h"
#include "../core/nav_services.h"
#include "../agent_manager/agent_manager.h"
#include <godot_cpp/variant/utility_functions.hpp>

namespace ffcore
{
	FlowFieldManager::FlowFieldManager()
	{
		fields.resize(MAX_FLOWFIELDS, nullptr);
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
		f->id = fid; // ← étape 2 : assignation

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
		f->id = fid;
		return fid;
	}

	void cleanup_flow_if_unused(FlowField *ff)
	{
		if (!ff)
			return;

		if (ff->refcount <= 0 && ff->id != INVALID_FLOWFIELD)
		{
			if (auto *agent_manager = get_global_agent_manager())
			{
				for (GroupID group = 1; group < MAX_GROUPS; group++)
				{
					if (agent_manager->get_group_flow(group) == ff)
						return;
				}
			}

			auto *fm = flowfields();
			if (fm)
			{
				fm->remove(ff->id);
				/* godot::UtilityFunctions::print("FF DELTED"); */
			}
		}
	}
}
