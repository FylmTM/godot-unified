// Little-endian byte writer/reader for file formats and wire messages. Every target we build for is
// little-endian (asserted), so fixed-width values are copied as-is.
#pragma once

#include <bit>
#include <cstring>
#include <vector>

#include "core/base.h"

static_assert(std::endian::native == std::endian::little, "unified assumes a little-endian target");

namespace uni {

class ByteWriter {
public:
    explicit ByteWriter(std::vector<u8>& out) : out_(out) {}

    void put_u8(u8 v) { out_.push_back(v); }
    void put_i8(i8 v) { out_.push_back((u8)v); }
    void put_u16(u16 v) { raw(&v, 2); }
    void put_u32(u32 v) { raw(&v, 4); }
    void put_u64(u64 v) { raw(&v, 8); }
    void put_i64(i64 v) { raw(&v, 8); }
    void put_f32(f32 v) { raw(&v, 4); }
    void put_bytes(const void* p, usize n) { raw(p, n); }
    usize size() const { return out_.size(); }
    // Overwrite a previously written u32 (length back-patching).
    void patch_u32(usize at, u32 v) { std::memcpy(out_.data() + at, &v, 4); }

private:
    void raw(const void* p, usize n) {
        const u8* b = (const u8*)p;
        out_.insert(out_.end(), b, b + n);
    }
    std::vector<u8>& out_;
};

// Bounds-checked reader: a short read sets ok() to false and yields zeros, never reads past the end.
class ByteReader {
public:
    ByteReader(const u8* data, usize size) : data_(data), size_(size) {}

    u8 get_u8() { return get<u8>(); }
    i8 get_i8() { return (i8)get<u8>(); }
    u16 get_u16() { return get<u16>(); }
    u32 get_u32() { return get<u32>(); }
    u64 get_u64() { return get<u64>(); }
    i64 get_i64() { return get<i64>(); }
    f32 get_f32() { return get<f32>(); }
    const u8* get_bytes(usize n) {
        if (!take(n)) return nullptr;
        return data_ + pos_ - n;
    }
    bool ok() const { return ok_; }
    usize remaining() const { return size_ - pos_; }
    bool at_end() const { return pos_ == size_; }

private:
    bool take(usize n) {
        if (!ok_ || n > size_ - pos_) {
            ok_ = false;
            return false;
        }
        pos_ += n;
        return true;
    }
    template <class T>
    T get() {
        T v{};
        if (take(sizeof(T))) std::memcpy(&v, data_ + pos_ - sizeof(T), sizeof(T));
        return v;
    }
    const u8* data_;
    usize size_;
    usize pos_ = 0;
    bool ok_ = true;
};

} // namespace uni
