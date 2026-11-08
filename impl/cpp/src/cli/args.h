// Tiny `--flag value` parser for the CLI (spec/CORE.md §3).
#pragma once

#include <initializer_list>
#include <string>
#include <vector>

#include "core/base.h"

namespace cli {

class Args {
public:
    Args(int argc, char** argv, int first);

    bool has(const char* flag) const;
    std::string str(const char* flag, const char* def = "") const;
    i64 num(const char* flag, i64 def) const;
    u64 u64num(const char* flag, u64 def) const;
    // Exits with a usage error if a required flag is missing.
    std::string need(const char* flag) const;
    // Exits with a usage error on flags not in `known` (NULL-terminated).
    void allow(std::initializer_list<const char*> known) const;

private:
    const std::string* find(const char* flag) const;
    std::vector<std::pair<std::string, std::string>> kv_;
};

[[noreturn]] void usage_error(const char* fmt, ...);

} // namespace cli
