#include "net/session.h"

#include <thread>

#include "core/platform.h"
#include "net/loopback.h"

namespace net {

std::unique_ptr<DatagramSocket> wrap_netsim(std::unique_ptr<DatagramSocket> inner, const Profile& profile, u64 seed) {
    if (profile.ideal()) return inner;
    return std::make_unique<NetSimSocket>(std::move(inner), profile, seed);
}

SessionResult run_session(const SessionConfig& cfg) {
    SessionResult out;
    LoopbackHub hub;
    const bool late = cfg.late_join_player >= 0;

    std::unique_ptr<DatagramSocket> relay_socket;
    std::string err;
    if (cfg.udp) {
        relay_socket = open_udp(Address{0x7F000001u, 0}, err);
        UNI_CHECK(relay_socket, "session: %s", err.c_str());
    } else {
        relay_socket = hub.open(1);
    }
    const Address relay_addr = cfg.udp ? relay_socket->local_address() : Address{0, 1};

    RelayConfig rc;
    rc.seed = cfg.seed;
    rc.initial_players = cfg.clients - (late ? 1 : 0);
    rc.ticks = cfg.ticks;
    Relay relay(rc, std::make_unique<Host>(std::move(relay_socket), true));
    std::thread relay_thread([&] { out.relay = relay.run(); });

    out.clients.resize((usize)cfg.clients);
    auto make_client = [&](int player, bool late_join) {
        std::unique_ptr<DatagramSocket> sock;
        if (cfg.udp) {
            std::string e;
            sock = open_udp(Address{0x7F000001u, 0}, e);
            UNI_CHECK(sock, "session: %s", e.c_str());
        } else {
            sock = hub.open();
        }
        u64 netsim_seed = cfg.seed * 1000003u + (u64)player * 7919u + 17u;
        sock = wrap_netsim(std::move(sock), cfg.profile, netsim_seed);
        ClientConfig cc;
        cc.player = (u8)player;
        cc.late_join = late_join;
        cc.ticks = cfg.ticks;
        cc.label = "client" + std::to_string(player);
        return std::make_unique<Client>(cc, std::make_unique<Host>(std::move(sock), false), relay_addr);
    };

    std::vector<std::thread> threads;
    for (int p = 0; p < cfg.clients; ++p) {
        if (p == cfg.late_join_player) continue;
        std::shared_ptr<Client> c = make_client(p, false);
        threads.emplace_back([&out, p, c] { out.clients[(usize)p] = c->run(); });
    }
    if (late) {
        // The joiner connects once the relay clock reaches the requested tick.
        const u64 give_up = uni::platform::now_us() + (u64)cfg.ticks * 50'000u + 30'000'000u;
        while (relay.current_tick() < cfg.late_join_tick && uni::platform::now_us() < give_up)
            uni::platform::sleep_us(2000);
        const int p = cfg.late_join_player;
        std::shared_ptr<Client> c = make_client(p, true);
        threads.emplace_back([&out, p, c] { out.clients[(usize)p] = c->run(); });
    }
    for (std::thread& t : threads) t.join();
    relay_thread.join();
    return out;
}

} // namespace net
