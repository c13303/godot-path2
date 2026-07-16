#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace ffcore
{
    using FlowFieldID = std::uint32_t;
    using GroupID = std::uint32_t;

    constexpr FlowFieldID INVALID_FLOWFIELD = 0;
    constexpr GroupID INVALID_GROUP = 0;
    

    struct Vec2
    {
        double x = 0.0;
        double y = 0.0;

        Vec2() = default;
        Vec2(double px, double py) : x(px), y(py) {}

        inline Vec2 operator+(const Vec2 &v) const { return {x + v.x, y + v.y}; }
        inline Vec2 operator-(const Vec2 &v) const { return {x - v.x, y - v.y}; }
        inline Vec2 operator*(double s) const { return {x * s, y * s}; }
        inline Vec2 operator/(double s) const { return {x / s, y / s}; }
        inline Vec2 operator-() const { return {-x, -y}; }

        inline Vec2 &operator+=(const Vec2 &v)
        {
            x += v.x;
            y += v.y;
            return *this;
        }

        inline Vec2 &operator-=(const Vec2 &v)
        {
            x -= v.x;
            y -= v.y;
            return *this;
        }

        inline double length() const { return std::sqrt(x * x + y * y); }
        inline double length_squared() const { return x * x + y * y; }

        inline Vec2 normalized() const
        {
            double l = length();
            return l > 1e-8 ? Vec2(x / l, y / l) : Vec2();
        }

        inline double dot(const Vec2 &v) const { return x * v.x + y * v.y; }

        inline double distance_to(const Vec2 &v) const
        {
            double dx = v.x - x;
            double dy = v.y - y;
            return std::sqrt(dx * dx + dy * dy);
        }

        inline Vec2 lerp(const Vec2 &other, double t) const
        {
            return *this + (other - *this) * t;
        }

        inline bool is_zero() const { return std::abs(x) < 1e-8 && std::abs(y) < 1e-8; }
    };

    struct Vec2i
    {
        int x = 0;
        int y = 0;

        Vec2i() = default;
        Vec2i(int px, int py) : x(px), y(py) {}

        inline bool operator==(const Vec2i &v) const { return x == v.x && y == v.y; }
        inline bool operator!=(const Vec2i &v) const { return !(*this == v); }
    };

    struct Vec3
    {
        double x = 0.0;
        double y = 0.0;
        double z = 0.0;
    };

    inline Vec2 closest_point_on_aabb(const Vec2 &p, const Vec2 &center, double half_w, double half_h)
    {
        return Vec2(
            std::clamp(p.x, center.x - half_w, center.x + half_w),
            std::clamp(p.y, center.y - half_h, center.y + half_h));
    }

    inline double point_aabb_distance(const Vec2 &p, const Vec2 &center, double half_w, double half_h)
    {
        Vec2 closest = closest_point_on_aabb(p, center, half_w, half_h);
        return (p - closest).length();
    }

    inline bool circle_overlaps_aabb(const Vec2 &circle_center, double circle_radius, const Vec2 &aabb_center, double half_w, double half_h)
    {
        if (circle_radius < 0.0)
            return false;
        double dist = point_aabb_distance(circle_center, aabb_center, half_w, half_h);
        return dist <= circle_radius;
    }

} // namespace ffcore
