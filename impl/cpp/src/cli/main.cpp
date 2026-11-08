// unified: headless core CLI (spec/CORE.md §3).
#include <cstdio>
#include <cstring>

#include "cli/commands.h"
#include "core/platform.h"

namespace {

struct Mode {
    const char* name;
    int (*run)(const cli::Args&);
};

const Mode MODES[] = {
    {"sim", cli::cmd_sim},           {"synctest", cli::cmd_synctest}, {"replay", cli::cmd_replay},
    {"snapshot", cli::cmd_snapshot}, {"resume", cli::cmd_resume},     {"bench", cli::cmd_bench},
    {"session", cli::cmd_session},   {"relay", cli::cmd_relay},       {"client", cli::cmd_client},
};

void print_usage() {
    std::fprintf(stderr,
                 "usage: unified <mode> [--flag value ...]\n"
                 "  sim       --ticks N [--seed S] [--players P] [--trace F] [--log F]\n"
                 "  synctest  --ticks N --window W [--seed S] [--players P]\n"
                 "  replay    --log F --trace F\n"
                 "  session   --clients N --transport loopback|udp --profile ideal|wan|bad --ticks N\n"
                 "            [--late-join P@T] [--log F] [--seed S]\n"
                 "  relay     --port P --players N --ticks T --log F\n"
                 "  client    --connect HOST:PORT --player I --ticks T [--profile ideal|wan|bad]\n"
                 "  snapshot  --ticks T --out F [--seed S] [--players P]\n"
                 "  resume    --in F --ticks N --trace F\n"
                 "  bench     --enemies E --window W --ticks N\n");
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        print_usage();
        return 2;
    }
    for (const Mode& m : MODES) {
        if (std::strcmp(argv[1], m.name) == 0) {
            uni::platform::init();
            cli::Args args(argc, argv, 2);
            int rc = m.run(args);
            uni::platform::shutdown();
            return rc;
        }
    }
    print_usage();
    return 2;
}
