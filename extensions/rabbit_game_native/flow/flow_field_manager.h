#pragma once
#include "CPathLib/core/types.h"
#include "CPathLib/flow/flow_field.h"
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
        int used_count() const;
        int capacity() const;
        void collect_occupied_ids(std::vector<FlowFieldID> &out) const;
        FlowFieldID id_for(const FlowField *field) const;
        int refcount(const FlowField *field) const;
        void retain(FlowField *field);
        void release(FlowField *field);
        void set_target_radius(FlowField *field, double radius);
        double target_radius(const FlowField *field) const;

    private:
        std::vector<FlowField *> fields;
        std::vector<int> refcounts;
        std::vector<double> target_radii;
    };

    void cleanup_flow_if_unused(FlowField *ff);

}
