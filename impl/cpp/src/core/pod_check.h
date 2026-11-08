// Compile-time proof that a state type is a pointer-free, portable POD.
//
// C++20 has no reflection, so this is the Boost.PFR trick in miniature: count an aggregate's fields by
// brace-initializing it from "convertible to anything" values, then bind them with structured bindings
// to recover each field's type, and recurse. A field passes if it's arithmetic, an enum, a uni::Array of
// passing fields, or a nested aggregate of passing fields. Pointers, references, raw C arrays (they break
// field counting through brace elision) and anything with constructors are rejected at compile time.
#pragma once

#include <type_traits>
#include <utility>

#include "core/base.h"

namespace uni::pod {

struct AnyField {
    template <class T>
    operator T() const; // declared only: used in unevaluated contexts
};

template <class T, class... A>
constexpr int field_count() {
    if constexpr (requires { T{A{}..., AnyField{}}; }) {
        return field_count<T, A..., AnyField>();
    } else {
        return (int)sizeof...(A);
    }
}

template <class T>
struct IsArray : std::false_type {};
template <class T, int N>
struct IsArray<uni::Array<T, N>> : std::true_type {
    using Elem = T;
};

template <class F>
constexpr bool field_ok();

template <class... F>
std::bool_constant<(field_ok<F>() && ...)> check_fields(const F&...); // declared only

// Structured bindings recover the field types. Extend the ladder if a state struct grows past 24 fields.
template <class T>
auto fields_ok(T& t) {
    constexpr int n = field_count<T>();
    static_assert(n >= 1 && n <= 24, "pod_check: aggregate field count out of range");
    // clang-format off
    if constexpr (n == 1) { auto& [a] = t; return check_fields(a); }
    else if constexpr (n == 2) { auto& [a, b] = t; return check_fields(a, b); }
    else if constexpr (n == 3) { auto& [a, b, c] = t; return check_fields(a, b, c); }
    else if constexpr (n == 4) { auto& [a, b, c, d] = t; return check_fields(a, b, c, d); }
    else if constexpr (n == 5) { auto& [a, b, c, d, e] = t; return check_fields(a, b, c, d, e); }
    else if constexpr (n == 6) { auto& [a, b, c, d, e, f] = t; return check_fields(a, b, c, d, e, f); }
    else if constexpr (n == 7) { auto& [a, b, c, d, e, f, g] = t; return check_fields(a, b, c, d, e, f, g); }
    else if constexpr (n == 8) { auto& [a, b, c, d, e, f, g, h] = t; return check_fields(a, b, c, d, e, f, g, h); }
    else if constexpr (n == 9) { auto& [a, b, c, d, e, f, g, h, i] = t; return check_fields(a, b, c, d, e, f, g, h, i); }
    else if constexpr (n == 10) { auto& [a, b, c, d, e, f, g, h, i, j] = t; return check_fields(a, b, c, d, e, f, g, h, i, j); }
    else if constexpr (n == 11) { auto& [a, b, c, d, e, f, g, h, i, j, k] = t; return check_fields(a, b, c, d, e, f, g, h, i, j, k); }
    else if constexpr (n == 12) { auto& [a, b, c, d, e, f, g, h, i, j, k, l] = t; return check_fields(a, b, c, d, e, f, g, h, i, j, k, l); }
    else if constexpr (n == 13) { auto& [a, b, c, d, e, f, g, h, i, j, k, l, m] = t; return check_fields(a, b, c, d, e, f, g, h, i, j, k, l, m); }
    else if constexpr (n == 14) { auto& [a, b, c, d, e, f, g, h, i, j, k, l, m, o] = t; return check_fields(a, b, c, d, e, f, g, h, i, j, k, l, m, o); }
    else if constexpr (n == 15) { auto& [a, b, c, d, e, f, g, h, i, j, k, l, m, o, p] = t; return check_fields(a, b, c, d, e, f, g, h, i, j, k, l, m, o, p); }
    else if constexpr (n == 16) { auto& [a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q] = t; return check_fields(a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q); }
    else if constexpr (n == 17) { auto& [a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q, r] = t; return check_fields(a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q, r); }
    else if constexpr (n == 18) { auto& [a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q, r, s] = t; return check_fields(a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q, r, s); }
    else if constexpr (n == 19) { auto& [a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q, r, s, u] = t; return check_fields(a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q, r, s, u); }
    else if constexpr (n == 20) { auto& [a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q, r, s, u, v] = t; return check_fields(a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q, r, s, u, v); }
    else if constexpr (n == 21) { auto& [a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q, r, s, u, v, w] = t; return check_fields(a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q, r, s, u, v, w); }
    else if constexpr (n == 22) { auto& [a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q, r, s, u, v, w, x] = t; return check_fields(a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q, r, s, u, v, w, x); }
    else if constexpr (n == 23) { auto& [a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q, r, s, u, v, w, x, y] = t; return check_fields(a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q, r, s, u, v, w, x, y); }
    else { auto& [a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q, r, s, u, v, w, x, y, z] = t; return check_fields(a, b, c, d, e, f, g, h, i, j, k, l, m, o, p, q, r, s, u, v, w, x, y, z); }
    // clang-format on
}

template <class F>
constexpr bool field_ok() {
    if constexpr (std::is_arithmetic_v<F> || std::is_enum_v<F>) {
        return true;
    } else if constexpr (IsArray<F>::value) {
        return field_ok<typename IsArray<F>::Elem>();
    } else if constexpr (std::is_pointer_v<F> || std::is_reference_v<F> || std::is_member_pointer_v<F> ||
                         std::is_array_v<F>) {
        return false;
    } else if constexpr (std::is_aggregate_v<F> && std::is_trivially_copyable_v<F> && std::is_standard_layout_v<F>) {
        return decltype(fields_ok(std::declval<F&>()))::value;
    } else {
        return false;
    }
}

// The whole check: trivially copyable (memcpy snapshots), standard layout (stable field order) and
// recursively pointer-free.
template <class T>
constexpr bool is_portable_pod() {
    return std::is_trivially_copyable_v<T> && std::is_standard_layout_v<T> && field_ok<T>();
}

} // namespace uni::pod
