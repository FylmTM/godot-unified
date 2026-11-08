// Offline modes: sim, synctest, replay, snapshot, resume, bench.
#include <algorithm>
#include <cinttypes>
#include <cstdio>

#include "cli/commands.h"
#include "core/input_log.h"
#include "core/json.h"
#include "core/platform.h"
#include "sim/sim.h"

namespace cli {

// ---- shared helpers ------------------------------------------------------------------------------

ScriptedInputs::ScriptedInputs(u64 seed, int players) {
    for (int p = 0; p < players; ++p) scripts_.emplace_back(seed, p);
}

uni::TickInputs ScriptedInputs::at(u32 tick, const sim::Sim& sim) {
    uni::TickInputs t;
    for (int p = 0; p < uni::MAX_PLAYERS; ++p) {
        t.players[p] = p < (int)scripts_.size() ? scripts_[p].input(tick, sim.levelup_pending(p)) : uni::ABSENT_INPUT;
    }
    return t;
}

void TraceWriter::add(u32 tick, u64 checksum) {
    if (!enabled()) return;
    char line[48];
    std::snprintf(line, sizeof line, "%06u %016" PRIx64 "\n", tick, checksum);
    text_ += line;
}

void TraceWriter::flush() {
    if (!enabled()) return;
    if (!uni::platform::write_file(path_, text_.data(), text_.size()))
        UNI_FATAL("cannot write trace %s", path_.c_str());
}

void print_json_line(const std::string& json) {
    std::fflush(stderr);
    std::printf("%s\n", json.c_str());
    std::fflush(stdout);
}

static int players_flag(const Args& a) {
    i64 p = a.num("--players", 4);
    if (p < 1 || p > uni::MAX_PLAYERS) usage_error("--players must be 1..4");
    return (int)p;
}

static u32 ticks_flag(const Args& a) {
    i64 n = a.num("--ticks", -1);
    if (n < 1) usage_error("--ticks N (N >= 1) is required");
    return (u32)n;
}

static double elapsed_ms(u64 t0) { return (double)(uni::platform::now_us() - t0) / 1000.0; }

// ---- sim -----------------------------------------------------------------------------------------

int cmd_sim(const Args& a) {
    a.allow({"--ticks", "--seed", "--players", "--trace", "--log"});
    const u32 ticks = ticks_flag(a);
    const u64 seed = a.u64num("--seed", 1);
    const int players = players_flag(a);
    TraceWriter trace(a.str("--trace"));
    uni::InputLog log;
    log.seed = seed;
    log.players = (u8)players;

    const u64 t0 = uni::platform::now_us();
    sim::Sim sim;
    sim.setup(seed, players);
    ScriptedInputs script(seed, players);
    u64 cs = 0;
    for (u32 k = 1; k <= ticks; ++k) {
        uni::TickInputs in = script.at(k, sim);
        sim.step(in);
        cs = sim.checksum();
        trace.add(k, cs);
        log.ticks.push_back(in);
    }
    trace.flush();
    if (a.has("--log") && !uni::write_input_log(a.str("--log"), log)) UNI_FATAL("cannot write log");

    uni::JsonWriter j;
    j.begin_object()
        .key("mode").value("sim")
        .key("ticks").value(ticks)
        .key("seed").value(seed)
        .key("players").value(players)
        .key("final_checksum").hex64(cs)
        .key("enemies_alive").value((int)sim.state().enemy_pool.count)
        .key("enemies_killed").value(sim.state().enemies_killed)
        .key("barrels_exploded").value(sim.state().barrels_exploded)
        .key("ms").value(elapsed_ms(t0))
        .end_object();
    print_json_line(j.str());
    return 0;
}

// ---- synctest ------------------------------------------------------------------------------------

int cmd_synctest(const Args& a) {
    a.allow({"--ticks", "--window", "--seed", "--players"});
    const u32 ticks = ticks_flag(a);
    const i64 window = a.num("--window", 8);
    if (window < 1 || window >= sim::RING_SIZE) usage_error("--window must be 1..%d", sim::RING_SIZE - 1);
    const u32 w = (u32)window;
    const u64 seed = a.u64num("--seed", 1);
    const int players = players_flag(a);

    const u64 t0 = uni::platform::now_us();
    sim::Sim sim;
    sim.setup(seed, players);
    ScriptedInputs script(seed, players);
    sim::Ring ring;
    std::vector<uni::TickInputs> inputs(ticks + 1);
    std::vector<u64> forward(ticks + 1);
    u64 mismatches = 0, resimulated = 0;
    for (u32 k = 1; k <= ticks; ++k) {
        sim.save(ring.at(k - 1));
        inputs[k] = script.at(k, sim);
        sim.step(inputs[k]);
        forward[k] = sim.checksum();
        if (k < w) continue;
        // Roll back W ticks and re-simulate them with the recorded inputs, re-saving as a client would.
        sim.restore(ring.at(k - w));
        UNI_CHECK(sim.tick() == k - w, "ring slot holds tick %u, wanted %u", sim.tick(), k - w);
        for (u32 j = k - w + 1; j <= k; ++j) {
            if (j > k - w + 1) sim.save(ring.at(j - 1));
            sim.step(inputs[j]);
            u64 cs = sim.checksum();
            ++resimulated;
            if (cs != forward[j]) {
                if (mismatches < 10)
                    std::fprintf(stderr, "synctest: mismatch at tick %u (rolled back at %u): %016" PRIx64
                                         " vs %016" PRIx64 "\n",
                                 j, k, cs, forward[j]);
                ++mismatches;
            }
        }
    }
    uni::JsonWriter j;
    j.begin_object()
        .key("mode").value("synctest")
        .key("ticks").value(ticks)
        .key("window").value(w)
        .key("mismatches").value(mismatches)
        .key("resimulated_ticks").value(resimulated)
        .key("final_checksum").hex64(forward[ticks])
        .key("ms").value(elapsed_ms(t0))
        .end_object();
    print_json_line(j.str());
    return mismatches == 0 ? 0 : 1;
}

// ---- replay --------------------------------------------------------------------------------------

int cmd_replay(const Args& a) {
    a.allow({"--log", "--trace"});
    uni::InputLog log;
    std::string err;
    if (!uni::read_input_log(a.need("--log"), log, err)) usage_error("replay: %s", err.c_str());
    TraceWriter trace(a.str("--trace"));
    const u64 t0 = uni::platform::now_us();
    sim::Sim sim;
    sim.setup(log.seed, log.players);
    u64 cs = 0;
    u32 k = 0;
    for (const uni::TickInputs& in : log.ticks) {
        sim.step(in);
        cs = sim.checksum();
        trace.add(++k, cs);
    }
    trace.flush();
    uni::JsonWriter j;
    j.begin_object()
        .key("mode").value("replay")
        .key("ticks").value(k)
        .key("seed").value(log.seed)
        .key("players").value((int)log.players)
        .key("final_checksum").hex64(cs)
        .key("ms").value(elapsed_ms(t0))
        .end_object();
    print_json_line(j.str());
    return 0;
}

// ---- snapshot / resume ---------------------------------------------------------------------------

int cmd_snapshot(const Args& a) {
    a.allow({"--ticks", "--out", "--seed", "--players"});
    const u32 ticks = ticks_flag(a);
    const u64 seed = a.u64num("--seed", 1);
    const int players = players_flag(a);
    const std::string out = a.need("--out");
    sim::Sim sim;
    sim.setup(seed, players);
    ScriptedInputs script(seed, players);
    for (u32 k = 1; k <= ticks; ++k) sim.step(script.at(k, sim));
    const u64 cs = sim.checksum();
    std::vector<u8> bytes = sim.encode_portable();
    if (!uni::platform::write_file(out, bytes.data(), bytes.size())) UNI_FATAL("cannot write %s", out.c_str());
    uni::JsonWriter j;
    j.begin_object()
        .key("mode").value("snapshot")
        .key("tick").value(ticks)
        .key("checksum").hex64(cs)
        .key("bytes").value((u64)bytes.size())
        .end_object();
    print_json_line(j.str());
    return 0;
}

int cmd_resume(const Args& a) {
    a.allow({"--in", "--ticks", "--trace"});
    const u32 ticks = ticks_flag(a);
    std::vector<u8> bytes;
    const std::string in = a.need("--in");
    if (!uni::platform::read_file(in, bytes)) usage_error("cannot read %s", in.c_str());
    sim::Sim sim;
    std::string err;
    if (!sim.load_portable(bytes.data(), bytes.size(), err)) usage_error("resume: %s", err.c_str());
    const u32 start = sim.tick();
    const u64 restored_cs = sim.checksum();
    ScriptedInputs script(sim.state().seed, (int)sim.state().initial_players);
    TraceWriter trace(a.str("--trace"));
    u64 cs = 0;
    for (u32 k = start + 1; k <= start + ticks; ++k) {
        sim.step(script.at(k, sim));
        cs = sim.checksum();
        trace.add(k, cs);
    }
    trace.flush();
    uni::JsonWriter j;
    j.begin_object()
        .key("mode").value("resume")
        .key("from_tick").value(start)
        .key("restored_checksum").hex64(restored_cs)
        .key("ticks").value(ticks)
        .key("final_checksum").hex64(cs)
        .end_object();
    print_json_line(j.str());
    return 0;
}

// ---- bench ---------------------------------------------------------------------------------------

namespace {
struct Samples {
    std::vector<double> us;
    void add(u64 t0, u64 t1) { us.push_back((double)(t1 - t0)); }
    void write(uni::JsonWriter& j, const char* name) {
        double mean = 0.0;
        for (double v : us) mean += v;
        mean = us.empty() ? 0.0 : mean / (double)us.size();
        std::vector<double> sorted = us;
        std::sort(sorted.begin(), sorted.end());
        double p99 = sorted.empty() ? 0.0 : sorted[std::min(sorted.size() - 1, (sorted.size() * 99) / 100)];
        j.key(name).begin_object().key("mean").value(mean).key("p99").value(p99).end_object();
    }
};
} // namespace

int cmd_bench(const Args& a) {
    a.allow({"--enemies", "--window", "--ticks", "--seed"});
    const int enemies = (int)a.num("--enemies", 1000);
    const i64 window = a.num("--window", 8);
    const u32 ticks = ticks_flag(a);
    const u64 seed = a.u64num("--seed", 1);
    if (enemies < 0 || enemies > game::MAX_ENEMIES) usage_error("--enemies must be 0..%d", game::MAX_ENEMIES);
    if (window < 1 || window >= sim::RING_SIZE) usage_error("--window must be 1..%d", sim::RING_SIZE - 1);
    const u32 w = (u32)window;
    using uni::platform::now_us;

    sim::Sim sim;
    sim.setup(seed, uni::MAX_PLAYERS);
    game::prespawn(sim.state(), enemies, enemies);
    ScriptedInputs script(seed, uni::MAX_PLAYERS);
    sim::Ring ring;
    std::vector<uni::TickInputs> inputs(ticks + w + 2);
    Samples step, save, restore, resim;
    u64 alive_sum = 0;
    usize snapshot_bytes = 0;
    const u32 warmup = w;
    for (u32 k = 1; k <= ticks + warmup; ++k) {
        const bool measure = k > warmup;
        u64 t0 = now_us();
        sim.save(ring.at(k - 1));
        u64 t1 = now_us();
        inputs[k] = script.at(k, sim);
        u64 t2 = now_us();
        sim.step(inputs[k]);
        u64 t3 = now_us();
        if (measure) {
            save.add(t0, t1);
            step.add(t2, t3);
            alive_sum += sim.state().enemy_pool.count;
            snapshot_bytes = ring.at(k - 1).bytes();
        }
        if (k < w) continue;
        u64 t4 = now_us();
        sim.restore(ring.at(k - w));
        u64 t5 = now_us();
        for (u32 jt = k - w + 1; jt <= k; ++jt) sim.step(inputs[jt]);
        u64 t6 = now_us();
        if (measure) {
            restore.add(t4, t5);
            resim.add(t5, t6);
        }
    }
    uni::JsonWriter j;
    j.begin_object().key("mode").value("bench").key("enemies").value(enemies).key("window").value(w);
    j.key("ticks").value(ticks);
    step.write(j, "step_us");
    save.write(j, "save_us");
    restore.write(j, "restore_us");
    resim.write(j, "resim_us");
    j.key("snapshot_bytes").value((u64)snapshot_bytes);
    j.key("state_bytes").value((u64)sizeof(game::State));
    j.key("enemies_alive_avg").value((double)alive_sum / (double)ticks);
    j.end_object();
    print_json_line(j.str());
    return 0;
}

} // namespace cli
