#ifndef FLOW_FIELD_H
#define FLOW_FIELD_H

#include <godot_cpp/classes/node2d.hpp>

namespace godot {

class FlowField : public Node2D
{
    GDCLASS(FlowField, Node2D);

protected:
    static void _bind_methods();

public:
    FlowField();
    ~FlowField();

    void _ready() override;
    
    // Setter/Getter
    void set_allow_diagonals(bool allow) { allow_diagonals = allow; }
    bool get_allow_diagonals() const { return allow_diagonals; }

private:
    bool allow_diagonals = false;
};

}  // namespace godot

#endif