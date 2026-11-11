// Ported from box3d src/math_internal.h at 3362633 (src/box3d_port/PORTING.md).
// SPDX-FileCopyrightText: 2025 Erin Catto
// SPDX-License-Identifier: MIT
package box3d_port

import "base:intrinsics"

TWO_PI :: f32(6.283185307)
PI_OVER_TWO :: f32(1.570796327)
PI_OVER_FOUR :: f32(0.785398163)
SQRT3 :: f32(1.732050808)

// todo eliminate this
BOUNDS3_EMPTY :: AABB{{FLT_MAX, FLT_MAX, FLT_MAX}, {-FLT_MAX, -FLT_MAX, -FLT_MAX}}

Matrix2 :: struct {
	cx, cy: Vec2,
}

Triangle :: struct {
	vertices:   [3]Vec3,
	i1, i2, i3: i32,
	flags:      i32,
}

TrianglePoint :: struct {
	point:   Vec3,
	feature: TriangleFeature,
}

ShapeExtent :: struct {
	minExtent: f32,
	maxExtent: Vec3,
}

// Align up to 8 byte alignment.
AlignUp8 :: proc(x: int) -> int {
	return (x + 7) & ~int(7)
}

// https://en.wikipedia.org/wiki/Floor_and_ceiling_functions
CeilingInt :: proc(numerator, denominator: i32) -> i32 {
	VALIDATE(denominator > 0)
	return (numerator + denominator - 1) / denominator
}

// Assumes denominator == 2^exponent
CeilingPow2 :: proc(numerator, denominator, exponent: i32) -> i32 {
	VALIDATE(exponent > 0 && (denominator == 1 << u32(exponent)))
	return (numerator + denominator - 1) >> u32(exponent)
}

Dot2 :: proc(v1, v2: Vec2) -> f32 {
	return v1.x * v2.x + v1.y * v2.y
}

Length2 :: proc(v: Vec2) -> f32 {
	return intrinsics.sqrt(Dot2(v, v))
}

LengthSquared2 :: proc(v: Vec2) -> f32 {
	return Dot2(v, v)
}

MinVec2 :: proc(v1, v2: Vec2) -> Vec2 {
	v: Vec2
	v.x = MinFloat(v1.x, v2.x)
	v.y = MinFloat(v1.y, v2.y)
	return v
}

MaxVec2 :: proc(v1, v2: Vec2) -> Vec2 {
	v: Vec2
	v.x = MaxFloat(v1.x, v2.x)
	v.y = MaxFloat(v1.y, v2.y)
	return v
}

Store :: proc(dst: [^]f32, src: Vec3) {
	dst[0] = src.x
	dst[1] = src.y
	dst[2] = src.z
}

ClampLength :: proc(v: Vec3, maxLength: f32) -> Vec3 {
	lengthSq := LengthSquared(v)
	if lengthSq <= maxLength * maxLength {
		return v
	}

	length := intrinsics.sqrt(lengthSq)
	return MulSV(maxLength / length, v)
}

// Assume v is a unit vector
ArbitraryPerp :: proc(v: Vec3) -> Vec3 {
	// Suppose vector a has all equal components and is a unit vector: a = (s, s, s)
	// Then 3*s*s = 1, s = sqrt(1/3) = 0.57735. This means that at least one component
	// of a unit vector must be greater or equal to 0.57735.
	p: Vec3
	if v.x < -0.5 || 0.5 < v.x {
		// x is non-zero and it should not go into the x component
		// dot([ay + bz, cx, dx], [x, y, z]) = ayx + bzx + cxy + dzx
		// for the dot product to be zero need: c = -a, d = -b
		a: f32 = 0.67
		b: f32 = -0.42
		p = Vec3{a * v.y + b * v.z, -a * v.x, -b * v.x}
	} else if v.y < -0.5 || 0.5 < v.y {
		// y is non-zero and it should not go into the y component
		// p = [ay, bx + cz, dy]
		// axy + bxy + cyz + dyz = 0
		// b = -a, d = -c
		a: f32 = 0.67
		c: f32 = -0.42
		p = Vec3{a * v.y, -a * v.x + c * v.z, -c * v.y}
	} else {
		// This would trip if the input is not a unit vector
		VALIDATE(v.z < -0.5 || 0.5 < v.z)

		// z is non-zero and it should not go into the z component
		// p = [az, bz, cx + dy]
		// axz + byz + cxz + dyz = 0
		// c = -a, d = -b
		a: f32 = 0.67
		b: f32 = -0.42
		p = Vec3{a * v.z, b * v.z, -a * v.x - b * v.y}
	}

	VALIDATE(LengthSquared(p) > 0.1)
	VALIDATE(AbsFloat(Dot(p, v)) < 100.0 * FLT_EPSILON)

	return Normalize(p)
}

QuatFromExponentialMap :: proc(v: Vec3) -> Quat {
	// Exponential map (Grassia)
	threshold: f32 = 0.018581361

	angle := Length(v)
	if angle < threshold {
		// Taylor expansion
		out: Quat
		out.v = MulSV(0.5 + angle * angle / 48.0, v)
		out.s = Cos(0.5 * angle)

		return out
	}

	return MakeQuatFromAxisAngle(MulSV(1.0 / angle, v), angle)
}

// Integrate rotation from angular velocity
// @param q1 initial rotation
// @param deltaRotation the angular displacement vector in radians (angular velocity multiplied by the time step)
// q2 = q1 + 0.5 * omega * q1
IntegrateRotation :: proc(q1: Quat, deltaRotation: Vec3) -> Quat {
	// https://fgiesen.wordpress.com/2012/08/24/quaternion-differentiation/
	qd := Quat{MulSV(0.5, deltaRotation), 0.0}
	qd = MulQuat(qd, q1)
	q2 := Quat{Add(q1.v, qd.v), qd.s + q1.s}
	q2 = NormalizeQuat(q2)
	return q2
	// unified: not ported: the disabled (#else) exponential map variant.
}

// Pseudo angular velocity from a quaternion target
// w = 2 * (target - q) * conj(q)
DeltaQuatToRotation :: proc(q: Quat, target: Quat) -> Vec3 {
	s := q
	if DotQuat(q, target) < 0.0 {
		// Correct polarity
		s = NegateQuat(q)
	}

	diff := Quat{Sub(target.v, s.v), target.s - s.s}
	product := MulQuat(diff, Conjugate(s))
	return MulSV(2.0, product.v)
}

ScalarTripleProduct :: proc(a, b, c: Vec3) -> f32 {
	d: Vec3
	d.x = b.y * c.z - b.z * c.y
	d.y = b.z * c.x - b.x * c.z
	d.z = b.x * c.y - b.y * c.x
	return a.x * d.x + a.y * d.y + a.z * d.z
}

// Get a value by index. Avoid undefined behavior of code like (&v.x)[2].
GetByIndex :: proc(v: Vec3, index: i32) -> f32 {
	VALIDATE(0 <= index && index < 3)
	temp := [3]f32{v.x, v.y, v.z}
	return temp[index]
}

MajorAxis :: proc(v: Vec3) -> i32 {
	return v.x < v.y ? (v.y < v.z ? 2 : 1) : (v.x < v.z ? 2 : 0)
}

MinElement :: proc(v: Vec3) -> f32 {
	return MinFloat(v.x, MinFloat(v.y, v.z))
}

MaxElement :: proc(v: Vec3) -> f32 {
	return MaxFloat(v.x, MaxFloat(v.y, v.z))
}

MaxElementIndex :: proc(v: Vec3) -> i32 {
	return v.x < v.y ? (v.y < v.z ? 2 : 1) : (v.x < v.z ? 2 : 0)
}

Add2 :: proc(a, b: Vec2) -> Vec2 {
	c := Vec2{a.x + b.x, a.y + b.y}
	return c
}

Sub2 :: proc(a, b: Vec2) -> Vec2 {
	c := Vec2{a.x - b.x, a.y - b.y}
	return c
}

Neg2 :: proc(v: Vec2) -> Vec2 {
	c := Vec2{-v.x, -v.y}
	return c
}

MulSV2 :: proc(s: f32, v: Vec2) -> Vec2 {
	c := Vec2{s * v.x, s * v.y}
	return c
}

// a + s * b
MulAdd2 :: proc(a: Vec2, s: f32, b: Vec2) -> Vec2 {
	c := Vec2{a.x + s * b.x, a.y + s * b.y}
	return c
}

// a - s * b
MulSub2 :: proc(a: Vec2, s: f32, b: Vec2) -> Vec2 {
	c := Vec2{a.x - s * b.x, a.y - s * b.y}
	return c
}

Cross2 :: proc(a, b: Vec2) -> f32 {
	return a.x * b.y - a.y * b.x
}

DistanceSquared2 :: proc(a, b: Vec2) -> f32 {
	dx := b.x - a.x
	dy := b.y - a.y
	return dx * dx + dy * dy
}

MulMV2 :: proc(m: Matrix2, a: Vec2) -> Vec2 {
	b := Vec2{m.cx.x * a.x + m.cy.x * a.y, m.cx.y * a.x + m.cy.y * a.y}
	return b
}

MulMM2 :: proc(m1, m2: Matrix2) -> Matrix2 {
	out: Matrix2
	out.cx = MulMV2(m1, m2.cx)
	out.cy = MulMV2(m1, m2.cy)
	return out
}

Det2 :: proc(m: Matrix2) -> f32 {
	return m.cx.x * m.cy.y - m.cx.y * m.cy.x
}

Invert2 :: proc(m: Matrix2) -> Matrix2 {
	det := Det2(m)
	if AbsFloat(det) > 1000.0 * FLT_MIN {
		invDet := 1.0 / det
		return Matrix2{{invDet * m.cy.y, -invDet * m.cx.y}, {-invDet * m.cy.x, invDet * m.cx.x}}
	}

	return Matrix2{{0.0, 0.0}, {0.0, 0.0}}
}

// Assumes positive semi-definite
Solve2 :: proc(m: Matrix2, b: Vec2) -> Vec2 {
	det := Det2(m)
	if det > 1000.0 * FLT_MIN {
		invDet := 1.0 / det
		return Vec2{invDet * m.cy.y * b.x - invDet * m.cy.x * b.y, -invDet * m.cx.y * b.x + invDet * m.cx.x * b.y}
	}

	return Vec2{0.0, 0.0}
}

// Convenience function: s * a + t * b + u * c
Blend3 :: proc(s: f32, a: Vec3, t: f32, b: Vec3, u: f32, c: Vec3) -> Vec3 {
	d := Vec3{s * a.x + t * b.x + u * c.x, s * a.y + t * b.y + u * c.y, s * a.z + t * b.z + u * c.z}
	return d
}

ModifiedCross :: proc(a, b: Vec3) -> Vec3 {
	c: Vec3
	c.x = a.y * b.z + a.z * b.y
	c.y = a.z * b.x + a.x * b.z
	c.z = a.x * b.y + a.y * b.x
	return c
}

MakeDiagonalMatrix :: proc(a, b, c: f32) -> Matrix3 {
	return Matrix3{{a, 0.0, 0.0}, {0.0, b, 0.0}, {0.0, 0.0, c}}
}

NormalizePlane :: proc(plane: Plane) -> Plane {
	invLength := 1.0 / Length(plane.normal)
	return Plane{MulSV(invLength, plane.normal), invLength * plane.offset}
}

MakePlaneFromNormalAndPoint :: proc(normal: Vec3, point: Vec3) -> Plane {
	return Plane{normal, Dot(normal, point)}
}

MakePlaneFromPoints :: proc(point1, point2, point3: Vec3) -> Plane {
	plane: Plane
	plane.normal = Cross(Sub(point2, point1), Sub(point3, point1))
	plane.normal = Normalize(plane.normal)
	plane.offset = Dot(plane.normal, point1)
	return plane
}

MakeNormalFromPoints :: proc(point1, point2, point3: Vec3) -> Vec3 {
	normal := Cross(Sub(point2, point1), Sub(point3, point1))
	return Normalize(normal)
}

// normal2 = q * normal1
// offset2 = dot(normal2, p) + offset1
TransformPlane :: proc(transform: Transform, plane: Plane) -> Plane {
	normal := RotateVector(transform.q, plane.normal)
	return Plane{normal, plane.offset + Dot(normal, transform.p)}
}

// Signed separation of a point from a plane
PlaneSeparation :: proc(plane: Plane, point: Vec3) -> f32 {
	return Dot(plane.normal, point) - plane.offset
}

// Negative if p is below the triangle v1-v2-v3
SignedVolume :: proc(v1, v2, v3, p: Vec3) -> f32 {
	e1 := Sub(v2, v1)
	e2 := Sub(v3, v1)
	n := Cross(e1, e2)
	return Dot(n, Sub(p, v1))
}

// todo eliminate this
IsWithinSegments :: proc(result: ^SegmentDistanceResult) -> bool {
	return (0.0 <= result.fraction1 && result.fraction1 <= 1.0) && (0.0 <= result.fraction2 && result.fraction2 <= 1.0)
}

RotateInertia :: proc(q: Quat, centralInertia: Matrix3) -> Matrix3 {
	rotationMatrix := MakeMatrixFromQuat(q)
	inertia := MulMM(rotationMatrix, MulMM(centralInertia, Transpose(rotationMatrix)))
	return inertia
}

TransformInertia :: proc(transform: Transform, centralInertia: Matrix3, mass: f32) -> Matrix3 {
	inertia := RotateInertia(transform.q, centralInertia)
	inertia = AddMM(inertia, Steiner(mass, transform.p))
	return inertia
}

// Add a point to an AABB.
AABB_AddPoint :: proc(a: AABB, point: Vec3) -> AABB {
	return AABB{Min(a.lowerBound, point), Max(a.upperBound, point)}
}
