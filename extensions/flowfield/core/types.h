#pragma once
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

} // namespace ffcore
