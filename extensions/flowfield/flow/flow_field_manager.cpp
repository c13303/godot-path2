#include "flow_field_manager.h"

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
		return register_existing(f);
	}

	FlowFieldID FlowFieldManager::register_copy(const FlowField &src)
	{
		FlowField *f = new FlowField(src.width(), src.height(), src.tile_size());
		f->copy_from(src);
		return register_existing(f);
	}
}
