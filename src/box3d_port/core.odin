// Ported from box3d src/core.c and src/core.h at 3362633 (src/box3d_port/PORTING.md).
// SPDX-FileCopyrightText: 2025 Erin Catto
// SPDX-License-Identifier: MIT
package box3d_port

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"

// unified: the platform, CPU, SIMD and compiler detection macros are Odin's ODIN_OS/ODIN_ARCH; the port has one
// 4-wide SIMD path on every platform (PORTING.md, SIMD).
B3_DEBUG :: #config(BOX3D_DEBUG, false) // the C library is built with NDEBUG; -define:BOX3D_DEBUG=true turns on its debug checks
// unified end

AtomicInt :: struct {
	value: i32,
}

AtomicU32 :: struct {
	value: u32,
}

AtomicI64 :: struct #align (8) {
	// 64-bit atomic wants 8-byte alignment
	value: i64,
}

// Minimum memory alignment used for all allocations
ALIGNMENT :: 32

// Use to validate definitions. Do not take my cookie.
SECRET_COOKIE :: 1152023

CHECK_DEF :: #force_inline proc(def: ^$T, loc := #caller_location) {
	assert(def.internalValue == SECRET_COOKIE, loc = loc)
}

CHECK_JOINT_DEF :: #force_inline proc(def: ^$T, loc := #caller_location) {
	assert(def.base.internalValue == SECRET_COOKIE, loc = loc)
}

// These macros help avoid sizeof bugs
ALLOC :: #force_inline proc($T: typeid, N: i32) -> [^]T {
	return cast([^]T)Alloc(int(N) * size_of(T))
}

FREE :: #force_inline proc(M: rawptr, $T: typeid, N: i32) {
	Free(M, int(N) * size_of(T))
}

GROW :: #force_inline proc(A: [^]$T, N, M: i32) -> [^]T {
	return cast([^]T)GrowAlloc(A, N * size_of(T), M * size_of(T))
}

GROW_ZERO :: #force_inline proc(A: [^]$T, N, M: i32) -> [^]T {
	return cast([^]T)GrowAllocZeroed(A, N * size_of(T), M * size_of(T))
}

// unified: floorf without core:math (exact: truncation, then one step down for negative non-integers)
floorf :: #force_inline proc "contextless" (x: f32) -> f32 {
	if !(abs(x) < 8388608.0) {
		return x // NaN, infinities and |x| >= 2^23 are already integral
	}
	t := f32(i32(x))
	if t == x {
		return x // keeps -0
	}
	return t > x ? t - 1 : t
}
// unified end

// This allows the user to change the length units at runtime
@(private = "file")
lengthUnitsPerMeter: f32 = 1.0

SetLengthUnitsPerMeter :: proc(lengthUnits: f32) {
	assert(IsValidFloat(lengthUnits) && lengthUnits > 0.0)
	lengthUnitsPerMeter = lengthUnits
	// unified: the length-scaled constants are package variables (public_constants.odin), not macros
	UpdateLengthUnitConstants()
	// unified end
}

GetLengthUnitsPerMeter :: proc() -> f32 {
	return lengthUnitsPerMeter
}

@(private = "file")
DefaultAssertFcn :: proc(condition: cstring, fileName: cstring, lineNumber: i32) -> i32 {
	fmt.printf("BOX3D ASSERTION: %s, %s, line %d\n", condition, fileName, lineNumber)
	// return non-zero to break to debugger
	return 1
}

AssertHandler: AssertFcn = DefaultAssertFcn

// unified: Odin's assert reports through context.assertion_failure_proc; the handler is kept for API parity.
SetAssertFcn :: proc(assertFcn: AssertFcn) {
	assert(assertFcn != nil)
	AssertHandler = assertFcn
}

InternalAssert :: proc(condition: cstring, fileName: cstring, lineNumber: i32) -> i32 {
	result := AssertHandler(condition, fileName, lineNumber)
	if result != 0 {
		intrinsics.debug_trap()
	}
	return result
}
// unified end

@(private = "file")
DefaultLogFcn :: proc(message: cstring) {
	fmt.printf("Box3D: %s\n", message)
}

LogHandler: LogFcn = DefaultLogFcn

SetLogFcn :: proc(logFcn: LogFcn) {
	assert(logFcn != nil)
	LogHandler = logFcn
}

// unified: Odin formatting (fmt verbs match printf's for what Box3D logs)
Log :: proc(format: string, args: ..any) {
	buffer: [512]u8
	s := fmt.bprintf(buffer[:len(buffer) - 1], format, ..args)
	buffer[len(s)] = 0
	LogHandler(cstring(&buffer[0]))
}
// unified end

GetVersion :: proc() -> Version {
	return Version{0, 2, 0}
}

IsDoublePrecision :: proc() -> bool {
	return false
}

GetMaxManifoldPoints :: proc() -> i32 {
	return MAX_MANIFOLD_POINTS
}

@(private = "file")
allocFcn: AllocFcn
@(private = "file")
freeFcn: FreeFcn
@(private = "file")
byteCount: AtomicI64

SetAllocator :: proc(allocFcn_: AllocFcn, freeFcn_: FreeFcn) {
	allocFcn = allocFcn_
	freeFcn = freeFcn_
}

Alloc :: proc(size: int) -> rawptr {
	if size == 0 {
		return nil
	}

	AtomicFetchAddI64(&byteCount, i64(size))

	// Allocation must be a multiple of ALIGNMENT (required by spec).
	alignedSize := ((size - 1) | (ALIGNMENT - 1)) + 1

	if allocFcn != nil {
		ptr := allocFcn(alignedSize, ALIGNMENT)
		assert(ptr != nil)
		assert((uintptr(ptr) & (ALIGNMENT - 1)) == 0)
		return ptr
	}

	// unified: Odin's heap allocator instead of aligned_alloc/_aligned_malloc
	bytes, err := mem.alloc_bytes_non_zeroed(alignedSize, ALIGNMENT, runtime.heap_allocator())
	assert(err == nil)
	ptr := raw_data(bytes)
	// unified end
	assert(ptr != nil)
	assert((uintptr(ptr) & (ALIGNMENT - 1)) == 0)
	return ptr
}

Free :: proc(mem_: rawptr, size: int) {
	if mem_ == nil {
		return
	}

	if freeFcn != nil {
		alignedSize := size > 0 ? ((size - 1) | (ALIGNMENT - 1)) + 1 : 0
		freeFcn(mem_, alignedSize)
	} else {
		// unified: Odin's heap allocator
		mem.free(mem_, runtime.heap_allocator())
		// unified end
	}

	AtomicFetchAddI64(&byteCount, -i64(size))
}

GrowAlloc :: proc(oldMem: rawptr, oldSize, newSize: i32) -> rawptr {
	assert(newSize > oldSize)
	newMem := Alloc(int(newSize))
	if oldSize > 0 {
		mem.copy_non_overlapping(newMem, oldMem, int(oldSize))
		Free(oldMem, int(oldSize))
	}
	return newMem
}

GrowAllocZeroed :: proc(oldMem: rawptr, oldSize, newSize: i32) -> rawptr {
	newMem := GrowAlloc(oldMem, oldSize, newSize)
	mem.zero(rawptr(uintptr(newMem) + uintptr(oldSize)), int(newSize - oldSize))
	return newMem
}

GetByteCount :: proc() -> i64 {
	return AtomicLoadI64(&byteCount)
}

AllocZero :: proc(size: int) -> rawptr {
	mem_ := Alloc(size)
	mem.zero(mem_, size)
	return mem_
}

// Not used. Keeping around in case I need this.
StrCpy :: proc(dst: [^]u8, size: i32, src: cstring) {
	assert(size > 0)
	if src != nil {
		s := ([^]u8)(src)
		i: i32 = 0
		for ; i < size - 1 && s[i] != 0; i += 1 {
			dst[i] = s[i]
		}
		for ; i < size; i += 1 {
			dst[i] = 0
		}
	} else {
		mem.zero(dst, int(size))
	}
}

Hash64NonZero :: proc(bytes: [^]u8, n: i32) -> u64 {
	if n <= 0 {
		return 1
	}

	h := rapidhash(bytes, int(n))
	return h == 0 ? 1 : h
}
