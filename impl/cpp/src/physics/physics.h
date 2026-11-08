// Box3D binding: the only module that includes box3d.h. It exposes what the game needs (bodies, rays,
// step) and the fork's world save/restore, with handles that are independent of the world instance so
// they can live in the pointer-free state block and travel inside snapshots.
#pragma once

#include "core/base.h"

struct b3WorldStateCache;
struct b3WorldState;

namespace phys {

// A Box3D body id without its world index. b3BodyId carries the world slot (world0), which differs
// between the clients of one process; storing it in the block would make checksums and snapshots
// depend on creation order of worlds. index1 == 0 means "no body".
struct BodyRef {
    i32 index1 = 0;
    u16 generation = 0;
    u16 reserved = 0;

    bool valid() const { return index1 != 0; }
};

struct Vec3 {
    f32 x = 0.0f, y = 0.0f, z = 0.0f;
};

// Shape categories: the ray casts classify hits by the shape's filter category, which is part of the
// physics snapshot (unlike user data pointers).
enum Category : u64 {
    CAT_STATIC = 1,
    CAT_CRATE = 2,
    CAT_BARREL = 4,
    CAT_PLAYER = 8,
};

struct RayHit {
    bool hit = false;
    Vec3 point;
    u64 category = 0;
    BodyRef body;
};

// Pose and velocities, as hashed by the checksum.
struct BodyState {
    Vec3 pos;
    f32 qx = 0.0f, qy = 0.0f, qz = 0.0f, qs = 1.0f;
    Vec3 lin;
    Vec3 ang;
};

// An owned, reusable physics snapshot buffer (b3WorldState).
class Snapshot {
public:
    Snapshot();
    ~Snapshot();
    Snapshot(Snapshot&& o) noexcept;
    Snapshot& operator=(Snapshot&& o) noexcept;
    Snapshot(const Snapshot&) = delete;
    Snapshot& operator=(const Snapshot&) = delete;

    const u8* data() const;
    usize size() const;
    // Fill from portable bytes (a file or the network). See world_state_ext.cpp.
    void assign(const u8* bytes, usize size);

    b3WorldState* raw() const { return state_; }

private:
    b3WorldState* state_;
};

class World {
public:
    World();
    ~World();
    World(const World&) = delete;
    World& operator=(const World&) = delete;

    BodyRef add_static_box(Vec3 pos, Vec3 half);
    BodyRef add_dynamic_box(Vec3 pos, f32 half, f32 density, u64 category);
    // Capsule along Y from (0, -half_height, 0) to (0, +half_height, 0).
    BodyRef add_capsule(Vec3 pos, f32 radius, f32 half_height, f32 density, u64 category, bool lock_rotation,
                        bool enable_sleep);
    void destroy_body(BodyRef body);

    Vec3 position(BodyRef body) const;
    Vec3 linear_velocity(BodyRef body) const;
    void set_linear_velocity(BodyRef body, Vec3 v);
    void apply_impulse_at_center(BodyRef body, Vec3 impulse);
    BodyState body_state(BodyRef body) const;

    RayHit cast_ray_closest(Vec3 origin, Vec3 translation) const;
    void step(f32 dt, int substeps);

    // Fork API. The geometry registry (cache) is primed right after the world's static setup so that a
    // fresh process that builds the same world interns hull geometry under the same ids: that's what
    // makes a saved image restorable in another process or on another OS.
    usize save(Snapshot& out);
    bool restore(const Snapshot& in);

private:
    u32 world_id_; // b3WorldId packed (index1 | generation << 16)
    b3WorldStateCache* cache_;
};

} // namespace phys
