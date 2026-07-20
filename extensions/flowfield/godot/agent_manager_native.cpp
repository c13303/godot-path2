#include "agent_manager_native.h"
#include "../core/types.h"
#include "../core/nav_config.h"
#include "../flow/flow_field.h"
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/classes/sprite2d.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include "../agent_manager/agent_manager.h"
#include <cstdlib>
#include <vector>
#include <algorithm>
#include "../godot/steering_system_native.h"
#include <godot_cpp/classes/engine.hpp>

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/object.hpp>
#include <cmath>

using namespace godot;

static Sprite2D *find_first_sprite(Node *node)
{
    if (!node)
        return nullptr;

    for (int i = 0; i < node->get_child_count(); ++i)
    {
        Node *child = node->get_child(i);
        if (auto *sprite = Object::cast_to<Sprite2D>(child))
            return sprite;
    }

    return nullptr;
}

static void apply_sprite_fight_hitbox(Node2D *node, ffcore::AgentProfile &profile)
{
    Sprite2D *sprite = find_first_sprite(node);
    if (!sprite)
        return;

    Ref<Texture2D> texture = sprite->get_texture();
    if (texture.is_null())
        return;

    Vector2 frame_size = texture->get_size();
    int hframes = sprite->get_hframes();
    int vframes = sprite->get_vframes();
    if (hframes > 1)
        frame_size.x /= static_cast<double>(hframes);
    if (vframes > 1)
        frame_size.y /= static_cast<double>(vframes);
    Vector2 scale = sprite->get_scale();
    Vector2 half_size(
        frame_size.x * std::abs(scale.x) * 0.5,
        frame_size.y * std::abs(scale.y) * 0.5);

    Vector2 center = sprite->get_position();
    if (!sprite->is_centered())
    {
        center.x += half_size.x;
        center.y += half_size.y;
    }

    profile.fight_offset_y = center.y;
    profile.fight_half_w = half_size.x;
    profile.fight_half_h = half_size.y;
}

void AgentManagerNative::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("create_group"), &AgentManagerNative::create_group);
    ClassDB::bind_method(D_METHOD("spawn_agent", "node", "group_id"), &AgentManagerNative::spawn_agent);
    ClassDB::bind_method(D_METHOD("assign_agent", "agent", "group"), &AgentManagerNative::assign_agent);
    ClassDB::bind_method(D_METHOD("set_current_selected_group", "group_id"), &AgentManagerNative::set_current_selected_group);
    ClassDB::bind_method(D_METHOD("cleanup_groups"), &AgentManagerNative::cleanup_groups);
    ClassDB::bind_method(D_METHOD("dissolve_group", "group_id"), &AgentManagerNative::dissolve_group);
    ClassDB::bind_method(D_METHOD("mark_group_has_order", "group_id"), &AgentManagerNative::mark_group_has_order);
    ClassDB::bind_method(D_METHOD("count_group_members", "group_id"), &AgentManagerNative::count_group_members);
    ClassDB::bind_method(D_METHOD("count_group_route_references", "group_id"), &AgentManagerNative::count_group_route_references);
    ClassDB::bind_method(D_METHOD("get_group_flow_wait", "group_id"), &AgentManagerNative::get_group_flow_wait);
    ClassDB::bind_method(D_METHOD("update_godot_agent", "node", "agent_id"), &AgentManagerNative::update_godot_agent);
    ClassDB::bind_method(D_METHOD("find_node_by_agent", "agent_id"), &AgentManagerNative::find_node_by_agent);
    ClassDB::bind_method(D_METHOD("unregister_agent", "agent_id"), &AgentManagerNative::unregister_agent);
    ClassDB::bind_method(D_METHOD("get_registration_debug_snapshot"), &AgentManagerNative::get_registration_debug_snapshot);
    ClassDB::bind_method(D_METHOD("send_agent_event", "event_name", "agent_id", "payload"), &AgentManagerNative::send_agent_event);
    ClassDB::bind_method(D_METHOD("set_agent_never_rest", "agent_id", "value"), &AgentManagerNative::set_agent_never_rest);
    ClassDB::bind_method(D_METHOD("set_agent_paused", "agent_id", "value"), &AgentManagerNative::set_agent_paused);
    ClassDB::bind_method(D_METHOD("set_agent_waiting_flow_group", "agent_id", "group_id"), &AgentManagerNative::set_agent_waiting_flow_group);
    ClassDB::bind_method(D_METHOD("set_agent_phase", "agent_id", "phase", "eating_seconds"), &AgentManagerNative::set_agent_phase);
    ClassDB::bind_method(D_METHOD("set_agent_traffic_state", "agent_id", "traffic_group_id", "traffic_priority"), &AgentManagerNative::set_agent_traffic_state);
    ClassDB::bind_method(D_METHOD("detach_agent_flow", "agent_id"), &AgentManagerNative::detach_agent_flow);
    ClassDB::bind_method(D_METHOD("assign_agent_path", "agent_id", "waypoints_world"), &AgentManagerNative::assign_agent_path);
    ClassDB::bind_method(D_METHOD("detach_agent_path", "agent_id"), &AgentManagerNative::detach_agent_path);
    ClassDB::bind_method(D_METHOD("agent_path_arrived", "agent_id"), &AgentManagerNative::agent_path_arrived);
    ADD_SIGNAL(MethodInfo("agent_event",
                          PropertyInfo(Variant::STRING, "event_name"),
                          PropertyInfo(Variant::INT, "agent_id"),
                          PropertyInfo(Variant::DICTIONARY, "payload")));
}

void AgentManagerNative::_ready()
{
    if (Engine::get_singleton()->is_editor_hint())
        return;

    core_mgr = ffcore::get_global_agent_manager();
    steering = ffcore::get_global_steering_system();

    Node *parent = get_parent();
    if (parent)
    {
        steering_native = Object::cast_to<SteeringSystemNative>(
            parent->get_node_or_null("SteeringSystemNative"));
    }

    if (!steering_native)
        UtilityFunctions::print("⚠️ AgentManagerNative: SteeringSystemNative introuvable");
}

AgentManagerNative::~AgentManagerNative() {}

AgentManagerNative::AgentManagerNative() : next_id(1) {}

void AgentManagerNative::emit_agent_event(const String &event_name, int agent_id, const Variant &payload)
{
    emit_signal("agent_event", event_name, agent_id, payload);
}

void AgentManagerNative::update_godot_agent(Node2D *node, int agent_id)
{
    if (!node)
        return;

    Dictionary payload;
    payload["node_path"] = node->get_path();
    payload["position"] = node->get_global_position();
    emit_agent_event("spawned", agent_id, payload);
}

Node2D *AgentManagerNative::find_node_by_agent(int agent_id)
{
    auto it = id_to_node.find(agent_id);
    if (it == id_to_node.end())
        return nullptr;
    return it->second;
}

void AgentManagerNative::unregister_agent(int agent_id)
{
    if (steering)
        steering->unregister_agent(agent_id);
    if (core_mgr)
        core_mgr->remove_agent(agent_id);
    if (steering_native)
        steering_native->unregister_node_mapping(agent_id);
    id_to_node.erase(agent_id);
}

// Builds a sorted PackedInt32Array from a scratch id vector (moves through sort
// in place). Local helper for the read-only registration snapshot only.
static PackedInt32Array sorted_packed_from_ids(std::vector<int> &ids)
{
    std::sort(ids.begin(), ids.end());
    PackedInt32Array out;
    out.resize((int)ids.size());
    for (int i = 0; i < (int)ids.size(); ++i)
        out.set(i, ids[i]);
    return out;
}

Dictionary AgentManagerNative::get_registration_debug_snapshot() const
{
    Dictionary snapshot;

    std::vector<int> core_ids;
    if (core_mgr)
        core_mgr->debug_collect_agent_ids(core_ids);
    snapshot["core_agent_ids"] = sorted_packed_from_ids(core_ids);

    std::vector<int> steering_ids;
    if (steering)
        steering->debug_collect_agent_ids(steering_ids);
    snapshot["steering_agent_ids"] = sorted_packed_from_ids(steering_ids);

    std::vector<int> node_ids;
    node_ids.reserve(id_to_node.size());
    for (const auto &entry : id_to_node)
        node_ids.push_back(entry.first);
    snapshot["agent_node_mapping_ids"] = sorted_packed_from_ids(node_ids);

    PackedInt32Array steering_node_ids;
    if (steering_native)
        steering_node_ids = steering_native->debug_get_node_mapping_ids();
    snapshot["steering_node_mapping_ids"] = steering_node_ids;

    return snapshot;
}

void AgentManagerNative::send_agent_event(const String &event_name, int agent_id, const Variant &payload)
{
    emit_agent_event(event_name, agent_id, payload);
}

int AgentManagerNative::create_group()
{
    return core_mgr ? core_mgr->create_group() : -1;
}

void AgentManagerNative::assign_agent(Node2D *agent, int group)
{
    if (!agent || !core_mgr)
        return;

    Vector2 p = agent->get_global_position();
    ffcore::Vec2 pos(p.x, p.y);

    int64_t nav_id = agent->get("nav_id").operator int64_t();
    core_mgr->add_agent_to_group(nav_id, group);
}

int AgentManagerNative::spawn_agent(Node2D *node, int group_id)
{
    if (group_id < 0)
    {
        UtilityFunctions::printerr("spawn_agent : group_id invalide");
        std::abort();
    }

    if (!core_mgr || !steering)
    {
        UtilityFunctions::printerr("spawn_agent : core_mgr ou steering absent");
        std::abort();
    }

    ffcore::Vec2 pos(node->get_global_position().x, node->get_global_position().y);

    int nav_id = next_id++;
    core_mgr->create_agent_entry(nav_id, pos, group_id);

    if (core_mgr->get(nav_id) == nullptr)
    {
        UtilityFunctions::print("CRITICAL: AgentManager n’a pas enregistré l’agent ", nav_id);
        std::abort();
    }

    double max_speed = ffcore::globalconfig().agent_max_speed;
    steering->register_agent_with_id(nav_id, pos, max_speed, nullptr);
    ffcore::AgentProfile profile;
    apply_sprite_fight_hitbox(node, profile);
    if (node->is_in_group(StringName("player")))
    {
        profile.smash_class = ffcore::SMASH_CLASS_PLAYER;
        profile.weapon_immune = true;
    }
    // Villager identity is assigned by AgentDefinitionService for every house
    // resident. Give that shared category the same weapon-smash class as the
    // other non-player combat targets; do not special-case individual villagers.
    else if (node->is_in_group(StringName("monsters")) || node->is_in_group(StringName("clients")) || node->is_in_group(StringName("villagers")))
        profile.smash_class = ffcore::SMASH_CLASS_MONSTER;
    else if (node->is_in_group(StringName("main_chars")))
        profile.smash_class = ffcore::SMASH_CLASS_MAIN_CHAR;

    // Per-agent stat overrides pushed from game-side definitions. Absent metas
    // leave the profile defaults untouched, so unrelated agent types keep their
    // default contact behavior.
    if (node->has_meta(StringName("monster_speed_scale")))
    {
        double scale = (double)node->get_meta(StringName("monster_speed_scale"));
        if (std::isfinite(scale) && scale > 0.0 && scale != 1.0)
            profile.max_speed = max_speed * scale;
    }
    if (node->has_meta(StringName("monster_crowd_resist")))
    {
        double resist = (double)node->get_meta(StringName("monster_crowd_resist"));
        if (std::isfinite(resist) && resist > 0.0)
            profile.crowd_resist_strength = resist;
    }
    if (node->has_meta(StringName("agent_contact_push_power")))
    {
        double power = (double)node->get_meta(StringName("agent_contact_push_power"));
        if (std::isfinite(power) && power >= 0.0)
            profile.contact_push_power = power;
    }
    if (node->has_meta(StringName("agent_contact_push_resist")))
    {
        double resist = (double)node->get_meta(StringName("agent_contact_push_resist"));
        if (std::isfinite(resist) && resist > 0.0)
            profile.contact_push_resist = resist;
    }
    if (node->has_meta(StringName("agent_contact_push_cooldown")))
    {
        double cooldown = (double)node->get_meta(StringName("agent_contact_push_cooldown"));
        if (std::isfinite(cooldown) && cooldown >= 0.0)
            profile.contact_push_cooldown = cooldown;
    }
    if (node->has_meta(StringName("agent_contact_push_friction_loss")))
    {
        double friction_loss = (double)node->get_meta(StringName("agent_contact_push_friction_loss"));
        if (std::isfinite(friction_loss))
            profile.contact_push_friction_loss = friction_loss;
    }
    if (node->has_meta(StringName("agent_contact_control_suppression_seconds")))
    {
        double suppression_seconds = (double)node->get_meta(StringName("agent_contact_control_suppression_seconds"));
        if (std::isfinite(suppression_seconds) && suppression_seconds >= 0.0)
            profile.contact_control_suppression_seconds = suppression_seconds;
    }
    if (node->has_meta(StringName("monster_smash_resist")))
    {
        double resist = (double)node->get_meta(StringName("monster_smash_resist"));
        if (std::isfinite(resist) && resist > 0.0)
            profile.smash_resist = resist;
    }
    if (node->has_meta(StringName("terrain_speed_channel")))
    {
        int channel = (int)node->get_meta(StringName("terrain_speed_channel"));
        if (channel >= ffcore::DEFAULT_TERRAIN_SPEED_CHANNEL)
            profile.terrain_speed_channel = channel;
    }

    steering->set_agent_profile(nav_id, profile);
    core_mgr->add_agent_to_group(nav_id, group_id);

    if (steering_native)
        steering_native->register_node_mapping(node, nav_id);

    id_to_node[nav_id] = node;

    return nav_id;
}

void AgentManagerNative::set_current_selected_group(ffcore::GroupID group)
{
    current_selected_group = group;
}

void AgentManagerNative::cleanup_groups()
{
    if (!core_mgr)
        return;

    for (ffcore::GroupID g = 1; g < ffcore::MAX_GROUPS; g++)
    {
        if (g == current_selected_group)
            continue;

        if (!core_mgr->is_group_active(g))
            continue;

        if (core_mgr->all_agents_inactive(g))
        {
            core_mgr->dissolve_group(g);
            continue;
        }

        core_mgr->mark_group_finished(g);
    }
}

void AgentManagerNative::dissolve_group(ffcore::GroupID group)
{
    if (!core_mgr)
        return;
    core_mgr->dissolve_group(group);
}

void AgentManagerNative::mark_group_has_order(ffcore::GroupID group)
{
    if (!core_mgr)
        return;

    core_mgr->mark_group_has_order(group);
}

int AgentManagerNative::count_group_members(ffcore::GroupID group) const
{
    if (!core_mgr)
        return 0;
    return core_mgr->count_group_members(group);
}

int AgentManagerNative::count_group_route_references(ffcore::GroupID group) const
{
    int count = core_mgr ? core_mgr->count_group_members(group) : 0;
    if (steering)
        count += steering->count_agents_waiting_flow_group(group);
    return count;
}

int AgentManagerNative::get_group_flow_wait(ffcore::GroupID group) const
{
    if (!core_mgr)
        return ffcore::GROUP_FLOW_WAIT_NONE;
    return core_mgr->get_group_flow_wait(group);
}

void AgentManagerNative::set_agent_never_rest(int agent_id, bool value)
{
    if (!steering)
        return;
    steering->set_agent_never_rest(agent_id, value);
}

void AgentManagerNative::set_agent_paused(int agent_id, bool value)
{
    if (!steering)
        return;
    steering->set_agent_paused(agent_id, value);
}

void AgentManagerNative::set_agent_waiting_flow_group(int agent_id, int group_id)
{
    if (!steering)
        return;
    steering->set_agent_waiting_flow_group(agent_id, (ffcore::GroupID)group_id);
}

void AgentManagerNative::set_agent_phase(int agent_id, int phase, float eating_seconds)
{
    if (!steering)
        return;
    steering->set_agent_phase(agent_id, static_cast<ffcore::AgentPhase>(phase), eating_seconds);
}

void AgentManagerNative::set_agent_traffic_state(int agent_id, std::int64_t traffic_group_id, int traffic_priority)
{
    if (!steering)
        return;
    steering->set_agent_traffic_state(agent_id, static_cast<std::int64_t>(traffic_group_id), traffic_priority);
}

void AgentManagerNative::detach_agent_flow(int agent_id)
{
    if (!steering)
        return;
    steering->set_agent_flow_ptr(agent_id, nullptr);
    if (core_mgr)
    {
        if (auto *entry = core_mgr->get(agent_id))
            entry->group = ffcore::GROUP_IDLE;
    }
}

void AgentManagerNative::assign_agent_path(int agent_id, const PackedVector2Array &waypoints_world)
{
    if (!steering)
        return;
    std::vector<ffcore::Vec2> waypoints;
    waypoints.reserve(waypoints_world.size());
    for (int i = 0; i < waypoints_world.size(); ++i)
    {
        Vector2 v = waypoints_world[i];
        waypoints.emplace_back(v.x, v.y);
    }
    steering->set_agent_path(agent_id, waypoints);
}

void AgentManagerNative::detach_agent_path(int agent_id)
{
    if (!steering)
        return;
    steering->clear_agent_path(agent_id);
}

bool AgentManagerNative::agent_path_arrived(int agent_id) const
{
    if (!steering)
        return false;
    return steering->agent_path_arrived(agent_id);
}
