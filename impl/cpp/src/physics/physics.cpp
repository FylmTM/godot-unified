#include "physics/physics.h"

#include <mutex>

#include "box3d/box3d.h"

namespace phys {

namespace {

// b3CreateWorld/b3DestroyWorld scan a global world table: serialize them across client threads.
std::mutex g_world_table_mutex;

b3WorldId unpack(u32 packed) { return b3WorldId{(u16)(packed & 0xFFFFu), (u16)(packed >> 16)}; }

u32 pack(b3WorldId id) { return (u32)id.index1 | ((u32)id.generation << 16); }

b3Vec3 v3(Vec3 v) { return b3Vec3{v.x, v.y, v.z}; }

Vec3 v3(b3Vec3 v) { return Vec3{v.x, v.y, v.z}; }

BodyRef ref_of(b3BodyId id) { return BodyRef{id.index1, id.generation, 0}; }

} // namespace

// ---- World ---------------------------------------------------------------------------------------

World::World() {
    b3WorldDef def = b3DefaultWorldDef();
    def.workerCount = 1; // no task callbacks: Box3D runs serially on the calling thread
    {
        std::lock_guard<std::mutex> lock(g_world_table_mutex);
        world_id_ = pack(b3CreateWorld(&def));
    }
    cache_ = b3CreateWorldStateCache();
}

World::~World() {
    {
        std::lock_guard<std::mutex> lock(g_world_table_mutex);
        b3DestroyWorld(unpack(world_id_));
    }
    b3DestroyWorldStateCache(cache_);
}

static b3BodyId body_id(u32 world, BodyRef ref) {
    UNI_ASSERT(ref.valid());
    return b3BodyId{ref.index1, (u16)(unpack(world).index1 - 1), ref.generation};
}

BodyRef World::add_static_box(Vec3 pos, Vec3 half) {
    b3BodyDef bd = b3DefaultBodyDef();
    bd.position = v3(pos);
    b3BodyId body = b3CreateBody(unpack(world_id_), &bd);
    b3ShapeDef sd = b3DefaultShapeDef();
    sd.filter.categoryBits = CAT_STATIC;
    b3BoxHull hull = b3MakeBoxHull(half.x, half.y, half.z);
    b3CreateHullShape(body, &sd, &hull.base);
    return ref_of(body);
}

BodyRef World::add_dynamic_box(Vec3 pos, f32 half, f32 density, u64 category) {
    b3BodyDef bd = b3DefaultBodyDef();
    bd.type = b3_dynamicBody;
    bd.position = v3(pos);
    b3BodyId body = b3CreateBody(unpack(world_id_), &bd);
    b3ShapeDef sd = b3DefaultShapeDef();
    sd.density = density;
    sd.filter.categoryBits = category;
    b3BoxHull hull = b3MakeCubeHull(half);
    b3CreateHullShape(body, &sd, &hull.base);
    return ref_of(body);
}

BodyRef World::add_capsule(Vec3 pos, f32 radius, f32 half_height, f32 density, u64 category, bool lock_rotation,
                           bool enable_sleep) {
    b3BodyDef bd = b3DefaultBodyDef();
    bd.type = b3_dynamicBody;
    bd.position = v3(pos);
    if (lock_rotation) {
        bd.motionLocks.angularX = true;
        bd.motionLocks.angularY = true;
        bd.motionLocks.angularZ = true;
    }
    bd.enableSleep = enable_sleep;
    b3BodyId body = b3CreateBody(unpack(world_id_), &bd);
    b3ShapeDef sd = b3DefaultShapeDef();
    sd.density = density;
    sd.filter.categoryBits = category;
    b3Capsule capsule = {b3Vec3{0.0f, -half_height, 0.0f}, b3Vec3{0.0f, half_height, 0.0f}, radius};
    b3CreateCapsuleShape(body, &sd, &capsule);
    return ref_of(body);
}

void World::destroy_body(BodyRef body) { b3DestroyBody(body_id(world_id_, body)); }

Vec3 World::position(BodyRef body) const { return v3(b3Body_GetPosition(body_id(world_id_, body))); }

Vec3 World::linear_velocity(BodyRef body) const { return v3(b3Body_GetLinearVelocity(body_id(world_id_, body))); }

void World::set_linear_velocity(BodyRef body, Vec3 v) { b3Body_SetLinearVelocity(body_id(world_id_, body), v3(v)); }

void World::apply_impulse_at_center(BodyRef body, Vec3 impulse) {
    b3Body_ApplyLinearImpulseToCenter(body_id(world_id_, body), v3(impulse), true);
}

BodyState World::body_state(BodyRef body) const {
    b3BodyId id = body_id(world_id_, body);
    BodyState s;
    s.pos = v3(b3Body_GetPosition(id));
    b3Quat q = b3Body_GetRotation(id);
    s.qx = q.v.x;
    s.qy = q.v.y;
    s.qz = q.v.z;
    s.qs = q.s;
    s.lin = v3(b3Body_GetLinearVelocity(id));
    s.ang = v3(b3Body_GetAngularVelocity(id));
    return s;
}

RayHit World::cast_ray_closest(Vec3 origin, Vec3 translation) const {
    b3RayResult r = b3World_CastRayClosest(unpack(world_id_), v3(origin), v3(translation), b3DefaultQueryFilter());
    RayHit hit;
    if (!r.hit) return hit;
    hit.hit = true;
    hit.point = v3(r.point);
    hit.category = b3Shape_GetFilter(r.shapeId).categoryBits;
    hit.body = ref_of(b3Shape_GetBody(r.shapeId));
    return hit;
}

void World::step(f32 dt, int substeps) { b3World_Step(unpack(world_id_), dt, substeps); }

usize World::save(Snapshot& out) {
    int n = b3World_SaveState(unpack(world_id_), cache_, out.raw());
    UNI_CHECK(n > 0, "b3World_SaveState failed");
    return (usize)n;
}

bool World::restore(const Snapshot& in) { return b3World_RestoreState(unpack(world_id_), cache_, in.raw()); }

// ---- Snapshot ------------------------------------------------------------------------------------

Snapshot::Snapshot() : state_(b3CreateWorldState()) {}

Snapshot::~Snapshot() { b3DestroyWorldState(state_); }

Snapshot::Snapshot(Snapshot&& o) noexcept : state_(o.state_) { o.state_ = b3CreateWorldState(); }

Snapshot& Snapshot::operator=(Snapshot&& o) noexcept {
    b3WorldState* tmp = state_;
    state_ = o.state_;
    o.state_ = tmp;
    return *this;
}

const u8* Snapshot::data() const { return b3WorldState_GetData(state_); }

usize Snapshot::size() const { return (usize)b3WorldState_GetSize(state_); }

} // namespace phys
