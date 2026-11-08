// Network modes: session (in-process relay + client threads), relay and client (separate processes, UDP).
#include <cstdio>
#include <cstdlib>

#include "cli/commands.h"
#include "core/input_log.h"
#include "core/json.h"
#include "core/platform.h"
#include "net/session.h"

namespace cli {

static net::Profile profile_flag(const Args& a) {
    net::Profile p;
    std::string name = a.str("--profile", "ideal");
    if (!net::profile_by_name(name, p)) usage_error("--profile must be ideal, wan or bad (got '%s')", name.c_str());
    return p;
}

static void write_log(const Args& a, const uni::InputLog& log) {
    if (!a.has("--log")) return;
    if (!uni::write_input_log(a.str("--log"), log)) UNI_FATAL("cannot write %s", a.str("--log").c_str());
}

int cmd_session(const Args& a) {
    a.allow({"--clients", "--transport", "--profile", "--ticks", "--late-join", "--log", "--seed"});
    net::SessionConfig cfg;
    cfg.clients = (int)a.num("--clients", 2);
    if (cfg.clients < 1 || cfg.clients > uni::MAX_PLAYERS) usage_error("--clients must be 1..4");
    std::string transport = a.str("--transport", "loopback");
    if (transport != "loopback" && transport != "udp") usage_error("--transport must be loopback or udp");
    cfg.udp = transport == "udp";
    cfg.profile = profile_flag(a);
    cfg.ticks = (u32)a.num("--ticks", 3600);
    cfg.seed = a.u64num("--seed", 1);
    if (a.has("--late-join")) {
        std::string lj = a.str("--late-join");
        usize at = lj.find('@');
        if (at == std::string::npos) usage_error("--late-join expects P@T");
        cfg.late_join_player = std::atoi(lj.substr(0, at).c_str());
        cfg.late_join_tick = (u32)std::atoi(lj.substr(at + 1).c_str());
        if (cfg.late_join_player < 0 || cfg.late_join_player >= cfg.clients || cfg.clients < 2)
            usage_error("--late-join player must be one of the --clients slots (and not the only one)");
    }

    const u64 t0 = uni::platform::now_us();
    net::SessionResult r = net::run_session(cfg);
    write_log(a, r.relay.log);

    bool ok = r.relay.ok;
    u64 desyncs = r.relay.desyncs;
    uni::JsonWriter j;
    j.begin_object()
        .key("mode").value("session")
        .key("transport").value(transport)
        .key("profile").value(cfg.profile.name)
        .key("ticks").value(cfg.ticks)
        .key("seed").value(cfg.seed)
        .key("desyncs").value(desyncs)
        .key("replaced_inputs").value(r.relay.replaced_inputs)
        .key("relay_finalized").value(r.relay.finalized);
    j.key("clients").begin_array();
    for (const net::ClientResult& c : r.clients) {
        j.raw(net::to_json(c));
        ok = ok && c.ok;
    }
    j.end_array();
    if (!r.relay.error.empty()) j.key("relay_error").value(r.relay.error);
    j.key("seconds").value((double)(uni::platform::now_us() - t0) / 1e6);
    j.key("ok").value(ok);
    j.end_object();
    print_json_line(j.str());
    return ok ? 0 : 1;
}

int cmd_relay(const Args& a) {
    a.allow({"--port", "--players", "--ticks", "--log"});
    net::RelayConfig rc;
    rc.initial_players = (int)a.num("--players", 2);
    rc.ticks = (u32)a.num("--ticks", 3600);
    rc.seed = 1; // relay and client have no --seed (spec/CORE.md §3)
    i64 port = a.num("--port", -1);
    if (port < 1 || port > 65535) usage_error("--port P is required");
    if (rc.initial_players < 1 || rc.initial_players > uni::MAX_PLAYERS) usage_error("--players must be 1..4");
    std::string err;
    auto sock = net::open_udp(net::Address{0, (u16)port}, err); // all interfaces: LAN play
    if (!sock) usage_error("relay: %s", err.c_str());
    std::fprintf(stderr, "relay: listening on udp port %d for %d players, %u ticks\n", (int)port, rc.initial_players,
                 rc.ticks);
    net::Relay relay(rc, std::make_unique<net::Host>(std::move(sock), true));
    net::RelayResult r = relay.run();
    write_log(a, r.log);
    uni::JsonWriter j;
    j.begin_object()
        .key("mode").value("relay")
        .key("desyncs").value(r.desyncs)
        .key("finalized").value(r.finalized)
        .key("replaced_inputs").value(r.replaced_inputs)
        .key("ok").value(r.ok);
    if (!r.error.empty()) j.key("error").value(r.error);
    j.end_object();
    print_json_line(j.str());
    return r.ok ? 0 : 1;
}

int cmd_client(const Args& a) {
    a.allow({"--connect", "--player", "--ticks", "--profile"});
    net::Address relay;
    std::string target = a.need("--connect");
    if (!net::parse_host_port(target, relay)) usage_error("--connect expects HOST:PORT (got '%s')", target.c_str());
    net::ClientConfig cc;
    i64 player = a.num("--player", -1);
    if (player < 0 || player >= uni::MAX_PLAYERS) usage_error("--player must be 0..3");
    cc.player = (u8)player;
    cc.ticks = (u32)a.num("--ticks", 0);
    cc.label = "client" + std::to_string(player);
    net::Profile profile = profile_flag(a);
    std::string err;
    auto sock = net::open_udp(net::Address{0, 0}, err);
    if (!sock) usage_error("client: %s", err.c_str());
    sock = net::wrap_netsim(std::move(sock), profile, 1000003u + (u64)player * 7919u + 17u);
    net::Client client(cc, std::make_unique<net::Host>(std::move(sock), false), relay);
    net::ClientResult r = client.run();
    print_json_line(net::to_json(r));
    return r.ok ? 0 : 1;
}

} // namespace cli
