#ifndef FFCORE_FLOW_FIELD_MANAGER_H
#define FFCORE_FLOW_FIELD_MANAGER_H

#include "flow_field.h"
#include "../core/nav_types.h"
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

	private:
		std::vector<FlowField *> fields;
	};
}

#endif
