// Odin binding generator for Godot's GDExtension API (run by `uni godot-gen`).
//
//   gen <api dir> <bindings.txt> <out dir>
//
// Inputs (committed in src/gdext/api/, dumped from the baseline Godot with
// `--dump-extension-api --dump-gdextension-interface-json`):
//   gdextension_interface.json  -> <out>/gdi/gdi.gen.odin   (package gdi: every C interface type and function pointer)
//   extension_api.json          -> <out>/api.gen.odin       (package gdext: builtin layouts, enums, class wrappers)
//
// Class wrappers use ptrcall: each argument is passed as a pointer to its encoded value (int -> i64,
// float -> f64, bool -> u8, objects -> the Object*, builtins -> their in-memory layout).
// String/StringName/NodePath parameters take Odin strings; returned strings live in context.temp_allocator.
// Methods with StringName parameters are a proc group: Odin strings, or interned ^StringName (gd.sn) with no
// per-call conversion.
// Methods returning a RefCounted class return `Ref(T)`: the caller owns one reference (`unref` it).
// Vararg methods (emit_signal, call, call_deferred...) go through a Variant call and take `..any`.
// Debug builds check that every class wrapper runs on Godot's main thread.
package gdext_gen

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// ---------------------------------------------------------------------------------------------- json helpers

J :: json.Value

jobj :: proc(v: J) -> json.Object {o, _ := v.(json.Object); return o}
jarr :: proc(v: J) -> json.Array {a, _ := v.(json.Array); return a}
jstr :: proc(o: json.Object, k: string) -> string {s, _ := o[k].(json.String); return s}
jbool :: proc(o: json.Object, k: string) -> bool {b, _ := o[k].(json.Boolean); return b}
jint :: proc(o: json.Object, k: string) -> i64 {
	#partial switch v in o[k] {
	case json.Integer:
		return v
	case json.Float:
		return i64(v)
	}
	return 0
}

load_json :: proc(path: string) -> json.Object {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", path, err)
		os.exit(1)
	}
	v, perr := json.parse(data, parse_integers = true)
	if perr != nil {
		fmt.eprintln("cannot parse", path, perr)
		os.exit(1)
	}
	return jobj(v)
}

ODIN_RESERVED :: []string {
	"context",
	"proc",
	"map",
	"in",
	"type",
	"struct",
	"enum",
	"union",
	"import",
	"package",
	"foreign",
	"when",
	"where",
	"defer",
	"do",
	"return",
	"for",
	"if",
	"else",
	"switch",
	"case",
	"break",
	"continue",
	"fallthrough",
	"distinct",
	"using",
	"cast",
	"transmute",
	"auto_cast",
	"dynamic",
	"bit_set",
	"matrix",
	"or_else",
	"or_return",
	"not_in",
	"len",
	"cap",
	"min",
	"max",
	"abs",
	"clamp",
	"size_of",
	"string",
	"rune",
	"int",
	"typeid",
	"any",
	"self",
	"bit_field",
	"or_break",
	"or_continue",
	"nil",
	"true",
	"false",
	"swizzle",
	"offset_of",
	"align_of",
	"type_of",
	"type_info_of",
	"typeid_of",
	"raw_data",
	"new",
	"free",
	"delete",
	"make",
	"append",
	"copy",
	"assert",
	"panic",
	"real",
	"imag",
	"complex",
	"quaternion",
	"conj",
	"expand_values",
}

safe_name :: proc(n: string) -> string {
	if slice.contains(ODIN_RESERVED, n) do return fmt.aprintf("%s_", n)
	return n
}

// ------------------------------------------------------------------------------------------ part 1: interface

c_scalar :: proc(s: string) -> (string, bool) {
	switch s {
	case "void":
		return "", true
	case "int8_t":
		return "i8", true
	case "uint8_t":
		return "u8", true
	case "int16_t":
		return "i16", true
	case "uint16_t":
		return "u16", true
	case "int32_t":
		return "i32", true
	case "uint32_t":
		return "u32", true
	case "int64_t":
		return "i64", true
	case "uint64_t":
		return "u64", true
	case "size_t":
		return "uint", true
	case "float":
		return "f32", true
	case "double":
		return "f64", true
	case "char":
		return "u8", true
	case "char16_t":
		return "u16", true
	case "char32_t":
		return "u32", true
	case "wchar_t":
		return "i32", true
	}
	return "", false
}

iface_kinds: map[string]string // type name -> kind

strip_gd :: proc(n: string) -> string {
	if strings.has_prefix(n, "GDExtension") && len(n) > len("GDExtension") do return n[len("GDExtension"):]
	return n
}

// C type string from gdextension_interface.json -> Odin type.
ctype :: proc(t: string) -> string {
	s := strings.trim_space(t)
	is_const := strings.has_prefix(s, "const ")
	if is_const do s = s[6:]
	stars := 0
	for strings.has_suffix(s, "*") {
		stars += 1
		s = strings.trim_space(s[:len(s) - 1])
	}
	base: string
	if sc, ok := c_scalar(s); ok {
		base = sc
	} else if s == "GDExtensionInterfaceFunctionPtr" {
		base = "rawptr"
	} else {
		base = strip_gd(s)
	}
	if stars == 0 do return base
	if stars == 1 {
		if base == "" do return "rawptr"
		if s == "char" do return is_const ? "cstring" : "[^]u8"
		if iface_kinds[s] == "struct" do return fmt.aprintf("^%s", base)
		return fmt.aprintf("[^]%s", base)
	}
	return "rawptr"
}

proc_sig :: proc(args: json.Array, ret: json.Object, has_ret: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "proc \"c\" (")
	for a, i in args {
		ao := jobj(a)
		if i > 0 do strings.write_string(&b, ", ")
		name := jstr(ao, "name")
		if name == "" do name = fmt.aprintf("p%d", i)
		fmt.sbprintf(&b, "%s: %s", safe_name(name), ctype(jstr(ao, "type")))
	}
	strings.write_string(&b, ")")
	if has_ret {
		rt := ctype(jstr(ret, "type"))
		if rt != "" do fmt.sbprintf(&b, " -> %s", rt)
	}
	return strings.to_string(b)
}

common_prefix :: proc(names: []string) -> string {
	if len(names) < 2 do return ""
	p := names[0]
	for n in names[1:] {
		i := 0
		for i < len(p) && i < len(n) && p[i] == n[i] do i += 1
		p = p[:i]
	}
	// cut back to the last '_'
	idx := strings.last_index_byte(p, '_')
	if idx < 0 do return ""
	return p[:idx + 1]
}

first_line :: proc(o: json.Object) -> string {
	d := jarr(o["description"])
	if len(d) == 0 do return ""
	s, _ := d[0].(json.String)
	return s
}

gen_interface :: proc(iface: json.Object) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "// GENERATED by src/gdext/gen from gdextension_interface.json. Do not edit.\n")
	strings.write_string(&b, "package gdi\n\n")
	types := jarr(iface["types"])
	for t in types {
		to := jobj(t)
		iface_kinds[jstr(to, "name")] = jstr(to, "kind")
	}
	for t in types {
		to := jobj(t)
		name := strip_gd(jstr(to, "name"))
		switch jstr(to, "kind") {
		case "handle":
			fmt.sbprintf(&b, "%s :: rawptr\n", name)
		case "alias":
			fmt.sbprintf(&b, "%s :: %s\n", name, ctype(jstr(to, "type")))
		case "enum":
			vals := jarr(to["values"])
			names := make([]string, len(vals))
			for v, i in vals do names[i] = jstr(jobj(v), "name")
			pre := common_prefix(names)
			fmt.sbprintf(&b, "%s :: enum i32 {{\n", name)
			for v in vals {
				vo := jobj(v)
				vn := jstr(vo, "name")[len(pre):]
				if len(vn) > 0 && vn[0] >= '0' && vn[0] <= '9' do vn = fmt.aprintf("_%s", vn)
				fmt.sbprintf(&b, "\t%s = %d,\n", vn, jint(vo, "value"))
			}
			strings.write_string(&b, "}\n")
		case "struct":
			fmt.sbprintf(&b, "%s :: struct {{\n", name)
			for m in jarr(to["members"]) {
				mo := jobj(m)
				fmt.sbprintf(&b, "\t%s: %s,\n", safe_name(jstr(mo, "name")), ctype(jstr(mo, "type")))
			}
			strings.write_string(&b, "}\n")
		case "function":
			ret := jobj(to["return_value"])
			fmt.sbprintf(&b, "%s :: #type %s\n", name, proc_sig(jarr(to["arguments"]), ret, ret != nil))
		}
	}
	strings.write_string(&b, "\n// Interface functions, filled by load().\n")
	funcs := jarr(iface["interface"])
	for f in funcs {
		fo := jobj(f)
		ret := jobj(fo["return_value"])
		if d := first_line(fo); d != "" do fmt.sbprintf(&b, "// %s\n", d)
		fmt.sbprintf(&b, "%s: %s\n", jstr(fo, "name"), proc_sig(jarr(fo["arguments"]), ret, ret != nil))
	}
	strings.write_string(&b, "\nload :: proc(gpa: InterfaceGetProcAddress) {\n")
	for f in funcs {
		n := jstr(jobj(f), "name")
		fmt.sbprintf(&b, "\t%s = auto_cast gpa(\"%s\")\n", n, n)
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

// ------------------------------------------------------------------------------------------------ part 2: api

classes: map[string]json.Object // all classes by name
wanted: map[string]bool // whitelisted classes (+ ancestors)
builtin_layout: map[string]bool // builtins with member offsets (plain structs)
builtin_flat: map[string]bool // ... whose members are all scalars (usable in default literals)
builtin_opaque: map[string]int // opaque builtins -> size
enum_types: map[string]string // "Class.Enum" / "Enum" -> Odin type name
variant_type_index: map[string]int // builtin name -> Variant::Type

Arg_Kind :: enum {
	Bool,
	Int,
	Float,
	Enum,
	String,
	StringName,
	NodePath,
	Builtin, // passed by value, slot is the same type
	Object,
	Pointer,
}

Type_Info :: struct {
	kind:  Arg_Kind,
	param: string, // Odin parameter / return type
	slot:  string, // ptrcall encoding
	refc:  bool, // a RefCounted class (returned as Ref(T))
}

is_refcounted :: proc(name: string) -> bool {
	cur := name
	for cur != "" {
		if cur == "RefCounted" do return true
		co, ok := classes[cur]
		if !ok do return false
		cur = jstr(co, "inherits")
	}
	return false
}

// The type of a returned value: RefCounted classes come back as an owned Ref(T).
ret_type :: proc(t: string, meta: string) -> Type_Info {
	ti := map_type(t, meta)
	if ti.kind == .Object && ti.refc do ti.param = fmt.aprintf("Ref(%s)", ti.param)
	return ti
}

builtin_name :: proc(t: string) -> string {
	if strings.has_prefix(t, "typedarray::") do return "Array"
	if strings.has_prefix(t, "typeddictionary::") do return "Dictionary"
	return t
}

map_type :: proc(t: string, meta: string) -> Type_Info {
	switch {
	case t == "bool":
		return {.Bool, "bool", "bool", false}
	case t == "int":
		return {.Int, "int", "i64", false}
	case t == "float":
		return {.Float, meta == "double" ? "f64" : "f32", "f64", false}
	case t == "String":
		return {.String, "string", "String", false}
	case t == "StringName":
		return {.StringName, "string", "StringName", false}
	case t == "NodePath":
		return {.NodePath, "string", "NodePath", false}
	case strings.has_prefix(t, "enum::") || strings.has_prefix(t, "bitfield::"):
		key := t[strings.index(t, "::") + 2:]
		if et, ok := enum_types[key]; ok do return {.Enum, et, "i64", false}
		return {.Int, "int", "i64", false}
	case strings.contains(t, "*"):
		return {.Pointer, "rawptr", "rawptr", false}
	case t == "Variant":
		return {.Builtin, "Variant", "Variant", false}
	}
	bn := builtin_name(t)
	if bn in builtin_layout || bn in builtin_opaque do return {.Builtin, bn, bn, false}
	if t in classes {
		rc := is_refcounted(t)
		if wanted[t] do return {.Object, t, "rawptr", rc}
		return {.Object, rc ? "RefCounted" : "Object", "rawptr", rc}
	}
	// native structures by value never appear as method args; fall back to an opaque pointer
	return {.Pointer, "rawptr", "rawptr", false}
}

is_number :: proc(s: string) -> bool {
	_, ok := strconv.parse_f64(s)
	return ok
}

// Godot default value -> Odin default expression, or "" if not expressible.
map_default :: proc(ti: Type_Info, raw_type: string, d: string) -> string {
	switch ti.kind {
	case .Bool:
		if d == "true" || d == "false" do return d
	case .Int:
		if is_number(d) do return d
	case .Float:
		if d == "inf" do return ""
		if is_number(d) do return d
	case .Enum:
		if is_number(d) do return fmt.aprintf("%s(%s)", ti.param, d)
	case .String, .StringName, .NodePath:
		s := d
		if strings.has_prefix(s, "&") do s = s[1:]
		if strings.has_prefix(s, "NodePath(") && strings.has_suffix(s, ")") do s = s[len("NodePath("):len(s) - 1]
		if len(s) >= 2 && s[0] == '"' && s[len(s) - 1] == '"' do return s
	case .Object:
		if d == "null" do return "{}"
	case .Builtin:
		// simple numeric constructors: Vector3(0, 1, 0), Color(1, 1, 1, 1)
		if builtin_flat[ti.param] && strings.has_prefix(d, ti.param) && strings.has_suffix(d, ")") {
			inner := d[len(ti.param):]
			if !strings.has_prefix(inner, "(") do return ""
			inner = inner[1:len(inner) - 1]
			parts := strings.split(inner, ",")
			for p in parts do if !is_number(strings.trim_space(p)) do return ""
			return fmt.aprintf("%s{{%s}}", ti.param, inner)
		}
	case .Pointer:
	}
	return ""
}

// Emits the conversion of parameter `name` into ptrcall slot `_aN`.
emit_arg_in :: proc(b: ^strings.Builder, ti: Type_Info, name: string, i: int) {
	switch ti.kind {
	case .Bool, .Builtin, .Pointer:
		fmt.sbprintf(b, "\t_a%d := %s\n", i, name)
	case .Int, .Enum:
		fmt.sbprintf(b, "\t_a%d := i64(%s)\n", i, name)
	case .Float:
		fmt.sbprintf(b, "\t_a%d := f64(%s)\n", i, name)
	case .String:
		fmt.sbprintf(b, "\t_a%d := string_from(%s); defer String_destroy(&_a%d)\n", i, name, i)
	case .StringName:
		if ti.param == "^StringName" {
			fmt.sbprintf(b, "\t_a%d := %s^ // borrowed: the caller keeps it alive\n", i, name)
		} else {
			fmt.sbprintf(b, "\t_a%d := string_name_from(%s); defer StringName_destroy(&_a%d)\n", i, name, i)
		}
	case .NodePath:
		fmt.sbprintf(b, "\t_a%d := node_path_from(%s); defer NodePath_destroy(&_a%d)\n", i, name, i)
	case .Object:
		fmt.sbprintf(b, "\t_a%d := %s.ptr\n", i, name)
	}
}

// Declares `_ret` for the return slot.
emit_ret_decl :: proc(b: ^strings.Builder, ti: Type_Info) {
	if ti.kind == .Builtin && ti.param in builtin_opaque && ti.param != "Variant" {
		fmt.sbprintf(b, "\t_ret := %s_new0()\n", ti.param) // default-construct (Array etc. aren't valid when zeroed)
	} else {
		fmt.sbprintf(b, "\t_ret: %s\n", ti.slot)
	}
}

emit_ret_out :: proc(b: ^strings.Builder, ti: Type_Info) {
	switch ti.kind {
	case .Bool, .Builtin, .Pointer:
		strings.write_string(b, "\treturn _ret\n")
	case .Int:
		strings.write_string(b, "\treturn int(_ret)\n")
	case .Enum:
		fmt.sbprintf(b, "\treturn %s(_ret)\n", ti.param)
	case .Float:
		fmt.sbprintf(b, "\treturn %s(_ret)\n", ti.param)
	case .String:
		strings.write_string(
			b,
			"\tdefer String_destroy(&_ret)\n\treturn string_to_odin(&_ret, context.temp_allocator)\n",
		)
	case .StringName:
		strings.write_string(
			b,
			"\tdefer StringName_destroy(&_ret)\n\treturn string_name_to_odin(&_ret, context.temp_allocator)\n",
		)
	case .NodePath:
		strings.write_string(
			b,
			"\tdefer NodePath_destroy(&_ret)\n\treturn node_path_to_odin(&_ret, context.temp_allocator)\n",
		)
	case .Object:
		fmt.sbprintf(b, "\treturn transmute(%s)_ret\n", ti.param)
	}
}

// Vararg methods: fixed arguments and `rest` become Variants, then a Variant call.
emit_vararg_body :: proc(b: ^strings.Builder, ps: []Param, self_ptr: string, has_ret: bool, rti: Type_Info) {
	fmt.sbprintf(b, "\t_vs := make([]Variant, %d + len(rest), context.temp_allocator)\n", len(ps))
	fmt.sbprintf(b, "\t_ps := make([]rawptr, %d + len(rest), context.temp_allocator)\n", len(ps))
	for p, i in ps {
		switch p.ti.kind {
		case .StringName:
			fmt.sbprintf(b, "\t_vs[%d] = variant_string_name(%s)\n", i, p.name)
		case .NodePath:
			fmt.sbprintf(b, "\t_vs[%d] = variant_node_path(%s)\n", i, p.name)
		case .Bool, .Int, .Float, .Enum, .String, .Builtin, .Object, .Pointer:
			fmt.sbprintf(b, "\t_vs[%d] = to_variant(%s)\n", i, p.name)
		}
	}
	fmt.sbprintf(b, "\tfor a, i in rest do _vs[%d + i] = variant_from_any(a)\n", len(ps))
	strings.write_string(b, "\tfor &v, i in _vs do _ps[i] = &v\n")
	strings.write_string(b, "\t_ret: Variant\n\t_err: gdi.CallError\n")
	fmt.sbprintf(b, "\tgdi.object_method_bind_call(_mb, %s, raw_data(_ps), i64(len(_ps)), &_ret, &_err)\n", self_ptr)
	strings.write_string(b, "\tfor &v in _vs do variant_destroy(&v)\n")
	strings.write_string(b, "\tif _err.error != .OK do call_error(_err, #procedure)\n")
	if !has_ret {
		strings.write_string(b, "\tvariant_destroy(&_ret)\n")
	} else if rti.param == "Variant" {
		strings.write_string(b, "\treturn _ret\n")
	} else {
		strings.write_string(b, "\tdefer variant_destroy(&_ret)\n")
		fmt.sbprintf(b, "\t_r, _ := from_variant(%s, &_ret)\n\treturn _r\n", rti.param)
	}
}

Param :: struct {
	name: string,
	ti:   Type_Info,
	def:  string,
}

collect_params :: proc(args: json.Array, raw_strings := false) -> []Param {
	ps := make([]Param, len(args))
	for a, i in args {
		ao := jobj(a)
		t := jstr(ao, "type")
		ti := map_type(t, jstr(ao, "meta"))
		if raw_strings && (ti.kind == .String || ti.kind == .StringName || ti.kind == .NodePath) do ti = {.Builtin, t, t, false}
		d := ""
		if dv, ok := ao["default_value"].(json.String); ok do d = map_default(ti, t, dv)
		ps[i] = {safe_name(jstr(ao, "name")), ti, d}
	}
	// Odin allows defaults anywhere, but keep them trailing so positional calls stay unambiguous.
	seen_required := false
	#reverse for &p in ps {
		if p.def == "" do seen_required = true
		else if seen_required do p.def = ""
	}
	return ps
}

write_params :: proc(b: ^strings.Builder, self_decl: string, ps: []Param) {
	strings.write_string(b, self_decl)
	for p, i in ps {
		if i > 0 || self_decl != "" do strings.write_string(b, ", ")
		fmt.sbprintf(b, "%s: %s", p.name, p.ti.param)
		if p.def != "" do fmt.sbprintf(b, " = %s", p.def)
	}
}

write_args_array :: proc(b: ^strings.Builder, ps: []Param) -> string {
	if len(ps) == 0 do return "nil"
	strings.write_string(b, "\t_args := [?]rawptr{")
	for _, i in ps {
		if i > 0 do strings.write_string(b, ", ")
		fmt.sbprintf(b, "&_a%d", i)
	}
	strings.write_string(b, "}\n")
	return "&_args[0]"
}

Stats :: struct {
	classes, methods, vararg, skipped_vararg, skipped_virtual, builtin_methods, sn_overloads: int,
}
stats: Stats

gen_class_method :: proc(b: ^strings.Builder, cname: string, m: json.Object) {
	if jbool(m, "is_virtual") {
		stats.skipped_virtual += 1
		return
	}
	stats.methods += 1
	vararg := jbool(m, "is_vararg")
	mname := jstr(m, "name")
	ps := collect_params(jarr(m["arguments"]))
	if vararg {
		stats.vararg += 1
		for &p in ps do p.def = "" // defaults before a variadic tail are not allowed
	}
	has_sn := false
	for p in ps do if p.ti.kind == .StringName do has_sn = true
	if vararg || !has_sn {
		gen_class_method_proc(b, cname, mname, fmt.aprintf("%s_%s", cname, mname), m, ps, vararg)
		return
	}
	// StringName parameters: a group of two, Odin strings (`_str`, converted per call) or interned
	// `^StringName`s (`_sn`, e.g. gd.sn("move_left"), no conversion): hot paths pass cached names.
	stats.sn_overloads += 1
	gen_class_method_proc(b, cname, mname, fmt.aprintf("%s_%s_str", cname, mname), m, ps, false)
	sn_ps := slice.clone(ps)
	for &p in sn_ps {
		if p.ti.kind != .StringName do continue
		p.ti = {.StringName, "^StringName", "StringName", false}
		p.def = ""
	}
	seen_required := false
	#reverse for &p in sn_ps {
		if p.def == "" do seen_required = true
		else if seen_required do p.def = ""
	}
	gen_class_method_proc(b, cname, mname, fmt.aprintf("%s_%s_sn", cname, mname), m, sn_ps, false)
	fmt.sbprintf(b, "%s_%s :: proc {{%s_%s_str, %s_%s_sn}}\n", cname, mname, cname, mname, cname, mname)
}

gen_class_method_proc :: proc(
	b: ^strings.Builder,
	cname, mname, pname: string,
	m: json.Object,
	ps: []Param,
	vararg: bool,
) {
	rv := jobj(m["return_value"])
	has_ret := rv != nil
	rti: Type_Info
	if has_ret do rti = ret_type(jstr(rv, "type"), jstr(rv, "meta"))
	is_static := jbool(m, "is_static")
	fmt.sbprintf(b, "%s :: proc(", pname)
	write_params(b, is_static ? "" : fmt.aprintf("self: %s", cname), ps)
	if vararg do strings.write_string(b, len(ps) > 0 || !is_static ? ", rest: ..any" : "rest: ..any")
	strings.write_string(b, ")")
	if has_ret do fmt.sbprintf(b, " -> %s", rti.param)
	strings.write_string(b, " {\n")
	strings.write_string(b, "\twhen ODIN_DEBUG do check_main_thread()\n")
	strings.write_string(b, "\t@(static) _mb: rawptr\n")
	fmt.sbprintf(b, "\tif _mb == nil do _mb = method_bind(\"%s\", \"%s\", %d)\n", cname, mname, jint(m, "hash"))
	if vararg {
		emit_vararg_body(b, ps, is_static ? "nil" : "self.ptr", has_ret, rti)
		strings.write_string(b, "}\n")
		return
	}
	for p, i in ps do emit_arg_in(b, p.ti, p.name, i)
	args := write_args_array(b, ps)
	if has_ret do emit_ret_decl(b, rti)
	fmt.sbprintf(
		b,
		"\tgdi.object_method_bind_ptrcall(_mb, %s, %s, %s)\n",
		is_static ? "nil" : "self.ptr",
		args,
		has_ret ? "&_ret" : "nil",
	)
	if has_ret do emit_ret_out(b, rti)
	strings.write_string(b, "}\n")
}

gen_builtin_method :: proc(b: ^strings.Builder, bname: string, vt: int, m: json.Object) {
	if jbool(m, "is_vararg") {
		stats.skipped_vararg += 1
		return
	}
	stats.builtin_methods += 1
	mname := jstr(m, "name")
	ps := collect_params(jarr(m["arguments"]))
	rt := jstr(m, "return_type")
	has_ret := rt != ""
	rti: Type_Info
	if has_ret do rti = ret_type(rt, "")
	is_static := jbool(m, "is_static")
	fmt.sbprintf(b, "%s_%s :: proc(", bname, mname)
	write_params(b, is_static ? "" : fmt.aprintf("self: ^%s", bname), ps)
	strings.write_string(b, ")")
	if has_ret do fmt.sbprintf(b, " -> %s", rti.param)
	strings.write_string(b, " {\n")
	strings.write_string(b, "\t@(static) _fp: gdi.PtrBuiltInMethod\n")
	fmt.sbprintf(
		b,
		"\tif _fp == nil do _fp = builtin_method(gdi.VariantType(%d), \"%s\", %d)\n",
		vt,
		mname,
		jint(m, "hash"),
	)
	for p, i in ps do emit_arg_in(b, p.ti, p.name, i)
	args := write_args_array(b, ps)
	if has_ret do emit_ret_decl(b, rti)
	fmt.sbprintf(
		b,
		"\t_fp(%s, %s, %s, %d)\n",
		is_static ? "nil" : "self",
		args == "nil" ? "nil" : args,
		has_ret ? "&_ret" : "nil",
		len(ps),
	)
	if has_ret do emit_ret_out(b, rti)
	strings.write_string(b, "}\n")
}

enum_name :: proc(scope: string, n: string) -> string {
	s, _ := strings.replace_all(n, ".", "_")
	if scope == "" do return s
	return fmt.aprintf("%s_%s", scope, s)
}

emit_enum :: proc(b: ^strings.Builder, tname: string, e: json.Object) {
	fmt.sbprintf(b, "%s :: enum i64 {{\n", tname)
	for v in jarr(e["values"]) {
		vo := jobj(v)
		fmt.sbprintf(b, "\t%s = %d,\n", jstr(vo, "name"), jint(vo, "value"))
	}
	strings.write_string(b, "}\n")
}

snake_field :: proc(n: string) -> string {
	return fmt.aprintf("base_%s", n)
}

variant_key :: proc(n: string) -> string {
	s, _ := strings.replace_all(strings.to_upper(n), "_", "")
	return s
}

gen_api :: proc(api: json.Object, cls_list, bi_list: []string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "// GENERATED by src/gdext/gen from extension_api.json. Do not edit.\n")
	strings.write_string(&b, "package gdext\n\nimport \"gdi\"\n\n")
	h := jobj(api["header"])
	fmt.sbprintf(&b, "API_VERSION :: \"%s\"\n\n", jstr(h, "version_full_name"))

	for c in jarr(api["classes"]) {
		co := jobj(c)
		classes[jstr(co, "name")] = co
	}
	for n in ([]string{"Object", "RefCounted"}) do wanted[n] = true
	for n in cls_list {
		cur := n
		for cur != "" {
			co, ok := classes[cur]
			if !ok {
				fmt.eprintln("unknown class", cur)
				os.exit(1)
			}
			wanted[cur] = true
			cur = jstr(co, "inherits")
		}
	}

	// Variant::Type indices from the global enum.
	for e in jarr(api["global_enums"]) {
		eo := jobj(e)
		if jstr(eo, "name") != "Variant.Type" do continue
		for v in jarr(eo["values"]) {
			vo := jobj(v)
			vn := jstr(vo, "name")
			if strings.has_prefix(vn, "TYPE_") do variant_type_index[variant_key(vn[5:])] = int(jint(vo, "value"))
		}
	}

	// Builtin layouts (float_64 = single-precision real_t, 64-bit pointers).
	strings.write_string(&b, "// ---- builtin types (build configuration float_64)\n\n")
	sizes: map[string]int
	for cfg in jarr(api["builtin_class_sizes"]) {
		co := jobj(cfg)
		if jstr(co, "build_configuration") != "float_64" do continue
		for s in jarr(co["sizes"]) {
			so := jobj(s)
			sizes[jstr(so, "name")] = int(jint(so, "size"))
		}
	}
	for cfg in jarr(api["builtin_class_member_offsets"]) {
		co := jobj(cfg)
		if jstr(co, "build_configuration") != "float_64" do continue
		for c in jarr(co["classes"]) {
			cl := jobj(c)
			name := jstr(cl, "name")
			builtin_layout[name] = true
			builtin_flat[name] = true
			fmt.sbprintf(&b, "%s :: struct {{\n", name)
			for m in jarr(cl["members"]) {
				mo := jobj(m)
				meta := jstr(mo, "meta")
				t := meta == "float" ? "f32" : meta == "int32" ? "i32" : meta
				if t == meta do builtin_flat[name] = false
				fmt.sbprintf(&b, "\t%s: %s, // offset %d\n", jstr(mo, "member"), t, jint(mo, "offset"))
			}
			fmt.sbprintf(&b, "}\n#assert(size_of(%s) == %d)\n", name, sizes[name])
		}
	}
	SKIP :: []string{"Nil", "bool", "int", "float", "Object"}
	for c in jarr(api["builtin_classes"]) {
		name := jstr(jobj(c), "name")
		if slice.contains(SKIP, name) || name in builtin_layout do continue
		builtin_opaque[name] = sizes[name]
		fmt.sbprintf(&b, "%s :: struct #align(8) {{ _opaque: [%d]u8 }}\n", name, sizes[name])
	}
	builtin_opaque["Variant"] = sizes["Variant"]
	fmt.sbprintf(&b, "Variant :: struct #align(8) {{ _opaque: [%d]u8 }}\n\n", sizes["Variant"])

	// Enums: global + wanted classes. Register names first so method signatures can use them.
	for e in jarr(api["global_enums"]) {
		eo := jobj(e)
		n := jstr(eo, "name")
		enum_types[n] = enum_name("", n)
	}
	for n in wanted {
		co := classes[n]
		for e in jarr(co["enums"]) {
			en := jstr(jobj(e), "name")
			enum_types[fmt.aprintf("%s.%s", n, en)] = enum_name(n, en)
		}
	}
	strings.write_string(&b, "// ---- global enums\n\n")
	for e in jarr(api["global_enums"]) {
		eo := jobj(e)
		emit_enum(&b, enum_name("", jstr(eo, "name")), eo)
	}

	// Opaque builtin constructors / destructors.
	strings.write_string(&b, "\n// ---- builtin constructors and destructors\n\n")
	for c in jarr(api["builtin_classes"]) {
		co := jobj(c)
		name := jstr(co, "name")
		if !(name in builtin_opaque) do continue
		vt := variant_type_index[variant_key(name)]
		for ctor in jarr(co["constructors"]) {
			cto := jobj(ctor)
			idx := jint(cto, "index")
			ps := collect_params(jarr(cto["arguments"]), raw_strings = true)
			for &p in ps do p.def = ""
			fmt.sbprintf(&b, "%s_new%d :: proc(", name, idx)
			write_params(&b, "", ps)
			fmt.sbprintf(&b, ") -> %s {{\n", name)
			strings.write_string(&b, "\t@(static) _fp: gdi.PtrConstructor\n")
			fmt.sbprintf(
				&b,
				"\tif _fp == nil do _fp = gdi.variant_get_ptr_constructor(gdi.VariantType(%d), %d)\n",
				vt,
				idx,
			)
			for p, i in ps do emit_arg_in(&b, p.ti, p.name, i)
			args := write_args_array(&b, ps)
			fmt.sbprintf(&b, "\t_ret: %s\n\t_fp(&_ret, %s)\n\treturn _ret\n}}\n", name, args)
		}
		if jbool(co, "has_destructor") {
			fmt.sbprintf(&b, "%s_destroy :: proc(self: ^%s) {{\n", name, name)
			strings.write_string(&b, "\t@(static) _fp: gdi.PtrDestructor\n")
			fmt.sbprintf(&b, "\tif _fp == nil do _fp = gdi.variant_get_ptr_destructor(gdi.VariantType(%d))\n", vt)
			strings.write_string(&b, "\t_fp(self)\n}\n")
		}
	}

	// Builtin methods for the whitelisted builtins.
	strings.write_string(&b, "\n// ---- builtin methods\n\n")
	for c in jarr(api["builtin_classes"]) {
		co := jobj(c)
		name := jstr(co, "name")
		if !slice.contains(bi_list, name) do continue
		vt := variant_type_index[variant_key(name)]
		for m in jarr(co["methods"]) do gen_builtin_method(&b, name, vt, jobj(m))
	}

	// Classes.
	names := make([dynamic]string)
	for n in wanted do append(&names, n)
	slice.sort(names[:])
	singletons: map[string]bool
	for s in jarr(api["singletons"]) do singletons[jstr(jobj(s), "name")] = true

	for n in names {
		stats.classes += 1
		co := classes[n]
		fmt.sbprintf(&b, "\n// ---- class %s\n\n", n)
		parent := jstr(co, "inherits")
		if parent == "" {
			fmt.sbprintf(&b, "%s :: struct {{ ptr: rawptr }}\n", n)
		} else {
			fmt.sbprintf(&b, "%s :: struct {{ using %s: %s }}\n", n, snake_field(parent), parent)
		}
		fmt.sbprintf(&b, "%s_CLASS :: \"%s\"\n", n, n)
		if jbool(co, "is_instantiable") && !singletons[n] {
			t := is_refcounted(n) ? fmt.aprintf("Ref(%s)", n) : n
			fmt.sbprintf(&b, "%s_new :: proc() -> %s {{ return transmute(%s)construct_object(\"%s\") }}\n", n, t, t, n)
		}
		if singletons[n] {
			fmt.sbprintf(&b, "%s_singleton :: proc() -> %s {{\n", n, n)
			strings.write_string(&b, "\t@(static) _s: rawptr\n")
			fmt.sbprintf(&b, "\tif _s == nil do _s = get_singleton(\"%s\")\n", n)
			fmt.sbprintf(&b, "\treturn transmute(%s)_s\n}}\n", n)
		}
		for c in jarr(co["constants"]) {
			cco := jobj(c)
			fmt.sbprintf(&b, "%s_%s :: %d\n", n, jstr(cco, "name"), jint(cco, "value"))
		}
		for e in jarr(co["enums"]) {
			eo := jobj(e)
			emit_enum(&b, enum_name(n, jstr(eo, "name")), eo)
		}
		for m in jarr(co["methods"]) do gen_class_method(&b, n, jobj(m))
	}
	return strings.to_string(b)
}

read_list :: proc(path: string) -> (cls, bi: []string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", path)
		os.exit(1)
	}
	c := make([dynamic]string)
	bl := make([dynamic]string)
	section := ""
	for line in strings.split_lines(string(data)) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' do continue
		if l[0] == '[' {
			section = l
			continue
		}
		if section == "[classes]" do append(&c, l)
		else if section == "[builtins]" do append(&bl, l)
	}
	return c[:], bl[:]
}

write_file :: proc(path: string, s: string) {
	if err := os.write_entire_file(path, transmute([]u8)s); err != nil {
		fmt.eprintln("cannot write", path, err)
		os.exit(1)
	}
}

main :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: gen <api dir> <bindings.txt> <out dir>")
		os.exit(2)
	}
	api_dir, list_path, out_dir := os.args[1], os.args[2], os.args[3]
	iface := load_json(fmt.aprintf("%s/gdextension_interface.json", api_dir))
	api := load_json(fmt.aprintf("%s/extension_api.json", api_dir))
	cls, bi := read_list(list_path)

	write_file(fmt.aprintf("%s/gdi/gdi.gen.odin", out_dir), gen_interface(iface))
	write_file(fmt.aprintf("%s/api.gen.odin", out_dir), gen_api(api, cls, bi))
	fmt.printf(
		"gen: %d classes (incl. ancestors), %d methods (%d vararg, %d with ^StringName overloads), %d builtin methods; skipped %d vararg, %d virtual\n",
		stats.classes,
		stats.methods,
		stats.vararg,
		stats.sn_overloads,
		stats.builtin_methods,
		stats.skipped_vararg,
		stats.skipped_virtual,
	)
}
