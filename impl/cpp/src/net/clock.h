// Tick timing shared by relay and client. Scheduling only: nothing here feeds the simulation.
#pragma once

#include <cmath>

#include "core/base.h"

namespace net {

constexpr double TICK_US = 1'000'000.0 / 60.0;

// Relay tick at relay time t (us) for a session whose tick 0 started at start_us.
inline i64 relay_tick_at(i64 t_us, i64 start_us) { return (i64)std::floor((double)(t_us - start_us) / TICK_US); }

} // namespace net
