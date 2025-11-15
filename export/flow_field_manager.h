#pragma once
#include "../core/types.h"
#include "flow_field.h"
#include "../core/nav_config.h"
#include <vector>

namespace ffcore
{
	class FlowFieldManager
	{
	public:
		FlowFieldManager();

		FlowFieldID register_existing(FlowField *f);
		FlowField *get(FlowFieldID id) const;
		void remove(FlowFieldID id);

		FlowFieldID create_field(int width, int height, double tile_size);
		FlowFieldID register_copy(const FlowField &src);

	private:
		std::vector<FlowField *> fields;
	};
}
