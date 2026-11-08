// A minimal JSON writer for the CLI's final stdout line.
#pragma once

#include <string>
#include <vector>

#include "core/base.h"

namespace uni {

class JsonWriter {
public:
    JsonWriter& begin_object();
    JsonWriter& end_object();
    JsonWriter& begin_array();
    JsonWriter& end_array();
    JsonWriter& key(const char* k);
    JsonWriter& value(i64 v);
    JsonWriter& value(u64 v);
    JsonWriter& value(int v) { return value((i64)v); }
    JsonWriter& value(u32 v) { return value((u64)v); }
    JsonWriter& value(double v);
    JsonWriter& value(bool v);
    JsonWriter& value(const char* s);
    JsonWriter& value(const std::string& s) { return value(s.c_str()); }
    JsonWriter& hex64(u64 v); // "%016x" string
    JsonWriter& raw(const std::string& json); // a pre-rendered JSON value

    const std::string& str() const { return out_; }

private:
    void sep();
    std::string out_;
    std::vector<bool> first_;
    bool after_key_ = false;
};

std::string hex16(u64 v);

} // namespace uni
