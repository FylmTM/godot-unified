#include "cli/args.h"

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace cli {

void usage_error(const char* fmt, ...) {
    std::fprintf(stderr, "unified: ");
    va_list ap;
    va_start(ap, fmt);
    std::vfprintf(stderr, fmt, ap);
    va_end(ap);
    std::fprintf(stderr, "\n");
    std::exit(2);
}

Args::Args(int argc, char** argv, int first) {
    for (int i = first; i < argc; i += 2) {
        const char* a = argv[i];
        if (std::strncmp(a, "--", 2) != 0) usage_error("unexpected argument '%s'", a);
        if (i + 1 >= argc || std::strncmp(argv[i + 1], "--", 2) == 0) usage_error("flag %s needs a value", a);
        kv_.emplace_back(a, argv[i + 1]);
    }
}

const std::string* Args::find(const char* flag) const {
    for (auto& [k, v] : kv_)
        if (k == flag) return &v;
    return nullptr;
}

bool Args::has(const char* flag) const { return find(flag) != nullptr; }

std::string Args::str(const char* flag, const char* def) const {
    const std::string* v = find(flag);
    return v ? *v : std::string(def);
}

i64 Args::num(const char* flag, i64 def) const {
    const std::string* v = find(flag);
    if (!v) return def;
    char* end = nullptr;
    long long n = std::strtoll(v->c_str(), &end, 10);
    if (!end || *end != '\0' || v->empty()) usage_error("%s expects an integer, got '%s'", flag, v->c_str());
    return (i64)n;
}

u64 Args::u64num(const char* flag, u64 def) const {
    const std::string* v = find(flag);
    if (!v) return def;
    char* end = nullptr;
    unsigned long long n = std::strtoull(v->c_str(), &end, 10);
    if (!end || *end != '\0' || v->empty()) usage_error("%s expects an integer, got '%s'", flag, v->c_str());
    return (u64)n;
}

std::string Args::need(const char* flag) const {
    const std::string* v = find(flag);
    if (!v) usage_error("missing required flag %s", flag);
    return *v;
}

void Args::allow(std::initializer_list<const char*> known) const {
    for (auto& [k, v] : kv_) {
        bool ok = false;
        for (const char* f : known) ok = ok || k == f;
        if (!ok) usage_error("unknown flag %s", k.c_str());
    }
}

} // namespace cli
