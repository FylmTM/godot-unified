#include "core/json.h"

#include <cinttypes>
#include <cmath>
#include <cstdio>

namespace uni {

std::string hex16(u64 v) {
    char buf[32];
    std::snprintf(buf, sizeof buf, "%016" PRIx64, v);
    return buf;
}

void JsonWriter::sep() {
    if (after_key_) {
        after_key_ = false;
        return;
    }
    if (!first_.empty()) {
        if (!first_.back()) out_ += ',';
        first_.back() = false;
    }
}

JsonWriter& JsonWriter::begin_object() {
    sep();
    out_ += '{';
    first_.push_back(true);
    return *this;
}

JsonWriter& JsonWriter::end_object() {
    out_ += '}';
    first_.pop_back();
    return *this;
}

JsonWriter& JsonWriter::begin_array() {
    sep();
    out_ += '[';
    first_.push_back(true);
    return *this;
}

JsonWriter& JsonWriter::end_array() {
    out_ += ']';
    first_.pop_back();
    return *this;
}

JsonWriter& JsonWriter::key(const char* k) {
    sep();
    out_ += '"';
    out_ += k;
    out_ += "\":";
    after_key_ = true;
    return *this;
}

JsonWriter& JsonWriter::value(i64 v) {
    sep();
    out_ += std::to_string(v);
    return *this;
}

JsonWriter& JsonWriter::value(u64 v) {
    sep();
    out_ += std::to_string(v);
    return *this;
}

JsonWriter& JsonWriter::value(double v) {
    sep();
    if (!std::isfinite(v)) {
        out_ += "null";
        return *this;
    }
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.3f", v);
    out_ += buf;
    return *this;
}

JsonWriter& JsonWriter::value(bool v) {
    sep();
    out_ += v ? "true" : "false";
    return *this;
}

JsonWriter& JsonWriter::value(const char* s) {
    sep();
    out_ += '"';
    for (const char* p = s; *p; ++p) {
        char c = *p;
        if (c == '"' || c == '\\') {
            out_ += '\\';
            out_ += c;
        } else if ((unsigned char)c < 0x20) {
            char buf[8];
            std::snprintf(buf, sizeof buf, "\\u%04x", (unsigned)c);
            out_ += buf;
        } else {
            out_ += c;
        }
    }
    out_ += '"';
    return *this;
}

JsonWriter& JsonWriter::hex64(u64 v) { return value(hex16(v)); }

JsonWriter& JsonWriter::raw(const std::string& json) {
    sep();
    out_ += json;
    return *this;
}

} // namespace uni
