// CLI modes (spec/CORE.md §3). Each returns the process exit code and prints one final JSON line.
#pragma once

#include <string>
#include <vector>

#include "cli/args.h"
#include "core/input.h"
#include "game/game.h"

namespace sim {
class Sim;
}

namespace cli {

int cmd_sim(const Args& a);
int cmd_synctest(const Args& a);
int cmd_replay(const Args& a);
int cmd_snapshot(const Args& a);
int cmd_resume(const Args& a);
int cmd_bench(const Args& a);
int cmd_session(const Args& a);
int cmd_relay(const Args& a);
int cmd_client(const Args& a);

// Scripted inputs for the first `players` slots; the rest are absent.
class ScriptedInputs {
public:
    ScriptedInputs(u64 seed, int players);
    uni::TickInputs at(u32 tick, const sim::Sim& sim);

private:
    std::vector<game::Script> scripts_;
};

// "%06d %016x\n" lines, written in one go at the end.
class TraceWriter {
public:
    explicit TraceWriter(std::string path) : path_(std::move(path)) {}
    void add(u32 tick, u64 checksum);
    bool enabled() const { return !path_.empty(); }
    void flush();

private:
    std::string path_;
    std::string text_;
};

void print_json_line(const std::string& json);

} // namespace cli
