// Workaround for a gap in the Box3D fork (third_party/box3d.patch): it can save a world into a
// b3WorldState and read the image's bytes, but it has no call to load an image from bytes (a file or a
// network message) back into a b3WorldState. Portable snapshots (late join, `resume`) need exactly that.
//
// b3WorldState is `struct { b3RecBuffer buffer; }` (src/world_state.c) and b3RecBuffer is
// `{ uint8_t* data; int capacity; int size; bool countOnly; }` (src/recording.h). We mirror that layout,
// allocate with Box3D's own allocator (b3Alloc/b3Free, so b3DestroyWorldState frees it correctly), and
// verify the mirror against the public getters on every assign. The proper fix is a two-line
// `b3WorldState_SetData` in the fork.
#include <cstring>

#include "box3d/box3d.h"
#include "physics/physics.h"

extern "C" {
void* b3Alloc(size_t size);
void b3Free(void* mem, size_t size);
}

namespace phys {

namespace {
struct RecBufferMirror {
    uint8_t* data;
    int capacity;
    int size;
    bool countOnly;
};
} // namespace

void Snapshot::assign(const u8* bytes, usize size) {
    UNI_CHECK(size > 0 && size < (usize)0x7FFFFFFF, "physics image of %zu bytes", size);
    RecBufferMirror* m = reinterpret_cast<RecBufferMirror*>(state_);
    UNI_CHECK(m->data == b3WorldState_GetData(state_) && m->size == b3WorldState_GetSize(state_) &&
                  m->capacity >= m->size && !m->countOnly,
              "b3WorldState layout differs from the mirror in world_state_ext.cpp");
    if (m->capacity < (int)size) {
        b3Free(m->data, (size_t)m->capacity);
        m->data = (uint8_t*)b3Alloc(size);
        m->capacity = (int)size;
    }
    std::memcpy(m->data, bytes, size);
    m->size = (int)size;
    UNI_CHECK(b3WorldState_GetSize(state_) == (int)size && b3WorldState_GetData(state_) == m->data,
              "b3WorldState mirror check failed after assign");
}

} // namespace phys
