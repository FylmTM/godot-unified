// In-process session: a relay thread plus one thread per client, over loopback or UDP, each client's link
// optionally behind the network simulator. Used by `unified session`; `relay`/`client` use the same
// Relay and Client classes in separate processes.
#pragma once

#include <memory>
#include <string>
#include <vector>

#include "net/client.h"
#include "net/netsim.h"
#include "net/relay.h"

namespace net {

struct SessionConfig {
    int clients = 2;
    bool udp = false;
    Profile profile;
    u32 ticks = 3600;
    u64 seed = 1;
    int late_join_player = -1; // -1: none
    u32 late_join_tick = 0;
};

struct SessionResult {
    RelayResult relay;
    std::vector<ClientResult> clients;
};

SessionResult run_session(const SessionConfig& cfg);

// A client-side socket: UDP (bound to an ephemeral port) or a loopback endpoint, wrapped in the network
// simulator unless the profile is ideal.
std::unique_ptr<DatagramSocket> wrap_netsim(std::unique_ptr<DatagramSocket> inner, const Profile& profile, u64 seed);

} // namespace net
