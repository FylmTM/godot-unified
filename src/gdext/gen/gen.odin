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

jobj :: proc(value: J) -> json.Object {result, _ := value.(json.Object); return result}
jarr :: proc(value: J) -> json.Array {result, _ := value.(json.Array); return result}
jstr :: proc(object: json.Object, key: string) -> string {result, _ := object[key].(json.String); return result}
jbool :: proc(object: json.Object, key: string) -> bool {result, _ := object[key].(json.Boolean); return result}
jint :: proc(object: json.Object, key: string) -> i64 {
	#partial switch number in object[key] {
	case json.Integer:
		return number
	case json.Float:
		return i64(number)
	}
	return 0
}

load_json :: proc(path: string) -> json.Object {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", path, err)
		os.exit(1)
	}
	root, perr := json.parse(data, parse_integers = true)
	if perr != nil {
		fmt.eprintln("cannot parse", path, perr)
		os.exit(1)
	}
	return jobj(root)
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

safe_name :: proc(name: string) -> string {
	if slice.contains(ODIN_RESERVED, name) do return fmt.aprintf("%s_", name)
	return name
}

// ------------------------------------------------------------------------------------------ part 1: interface

c_scalar :: proc(c_type: string) -> (string, bool) {
	switch c_type {
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

strip_gd :: proc(name: string) -> string {
	if strings.has_prefix(name, "GDExtension") && len(name) > len("GDExtension") do return name[len("GDExtension"):]
	return name
}

// C type string from gdextension_interface.json -> Odin type.
ctype :: proc(c_type: string) -> string {
	stripped := strings.trim_space(c_type)
	is_const := strings.has_prefix(stripped, "const ")
	if is_const do stripped = stripped[6:]
	stars := 0
	for strings.has_suffix(stripped, "*") {
		stars += 1
		stripped = strings.trim_space(stripped[:len(stripped) - 1])
	}
	base: string
	if scalar, ok := c_scalar(stripped); ok {
		base = scalar
	} else if stripped == "GDExtensionInterfaceFunctionPtr" {
		base = "rawptr"
	} else {
		base = strip_gd(stripped)
	}
	if stars == 0 do return base
	if stars == 1 {
		if base == "" do return "rawptr"
		if stripped == "char" do return is_const ? "cstring" : "[^]u8"
		if iface_kinds[stripped] == "struct" do return fmt.aprintf("^%s", base)
		return fmt.aprintf("[^]%s", base)
	}
	return "rawptr"
}

proc_sig :: proc(args: json.Array, ret: json.Object, has_ret: bool) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "proc \"c\" (")
	for arg, i in args {
		arg_object := jobj(arg)
		if i > 0 do strings.write_string(&builder, ", ")
		name := jstr(arg_object, "name")
		if name == "" do name = fmt.aprintf("p%d", i)
		fmt.sbprintf(&builder, "%s: %s", safe_name(name), ctype(jstr(arg_object, "type")))
	}
	strings.write_string(&builder, ")")
	if has_ret {
		return_type := ctype(jstr(ret, "type"))
		if return_type != "" do fmt.sbprintf(&builder, " -> %s", return_type)
	}
	return strings.to_string(builder)
}

common_prefix :: proc(names: []string) -> string {
	if len(names) < 2 do return ""
	prefix := names[0]
	for name in names[1:] {
		i := 0
		for i < len(prefix) && i < len(name) && prefix[i] == name[i] do i += 1
		prefix = prefix[:i]
	}
	// cut back to the last '_'
	idx := strings.last_index_byte(prefix, '_')
	if idx < 0 do return ""
	return prefix[:idx + 1]
}

first_line :: proc(object: json.Object) -> string {
	lines := jarr(object["description"])
	if len(lines) == 0 do return ""
	text, _ := lines[0].(json.String)
	return text
}

gen_interface :: proc(iface: json.Object) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "// GENERATED by src/gdext/gen from gdextension_interface.json. Do not edit.\n")
	strings.write_string(&builder, "package gdi\n\n")
	types := jarr(iface["types"])
	for type_value in types {
		type_object := jobj(type_value)
		iface_kinds[jstr(type_object, "name")] = jstr(type_object, "kind")
	}
	for type_value in types {
		type_object := jobj(type_value)
		name := strip_gd(jstr(type_object, "name"))
		switch jstr(type_object, "kind") {
		case "handle":
			fmt.sbprintf(&builder, "%s :: rawptr\n", name)
		case "alias":
			fmt.sbprintf(&builder, "%s :: %s\n", name, ctype(jstr(type_object, "type")))
		case "enum":
			vals := jarr(type_object["values"])
			names := make([]string, len(vals))
			for value, i in vals do names[i] = jstr(jobj(value), "name")
			prefix := common_prefix(names)
			fmt.sbprintf(&builder, "%s :: enum i32 {{\n", name)
			for value in vals {
				value_object := jobj(value)
				value_name := jstr(value_object, "name")[len(prefix):]
				if len(value_name) > 0 && value_name[0] >= '0' && value_name[0] <= '9' do value_name = fmt.aprintf("_%s", value_name)
				fmt.sbprintf(&builder, "\t%s = %d,\n", value_name, jint(value_object, "value"))
			}
			strings.write_string(&builder, "}\n")
		case "struct":
			fmt.sbprintf(&builder, "%s :: struct {{\n", name)
			for member in jarr(type_object["members"]) {
				member_object := jobj(member)
				fmt.sbprintf(
					&builder,
					"\t%s: %s,\n",
					safe_name(jstr(member_object, "name")),
					ctype(jstr(member_object, "type")),
				)
			}
			strings.write_string(&builder, "}\n")
		case "function":
			ret := jobj(type_object["return_value"])
			fmt.sbprintf(&builder, "%s :: #type %s\n", name, proc_sig(jarr(type_object["arguments"]), ret, ret != nil))
		}
	}
	strings.write_string(&builder, "\n// Interface functions, filled by load().\n")
	funcs := jarr(iface["interface"])
	for function in funcs {
		function_object := jobj(function)
		ret := jobj(function_object["return_value"])
		if description := first_line(function_object); description != "" do fmt.sbprintf(&builder, "// %s\n", description)
		fmt.sbprintf(
			&builder,
			"%s: %s\n",
			jstr(function_object, "name"),
			proc_sig(jarr(function_object["arguments"]), ret, ret != nil),
		)
	}
	strings.write_string(&builder, "\nload :: proc(gpa: InterfaceGetProcAddress) {\n")
	for function in funcs {
		name := jstr(jobj(function), "name")
		fmt.sbprintf(&builder, "\t%s = auto_cast gpa(\"%s\")\n", name, name)
	}
	strings.write_string(&builder, "}\n")
	return strings.to_string(builder)
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
		class_object, ok := classes[cur]
		if !ok do return false
		cur = jstr(class_object, "inherits")
	}
	return false
}

// The type of a returned value: RefCounted classes come back as an owned Ref(T).
ret_type :: proc(type_name: string, meta: string) -> Type_Info {
	type_info := map_type(type_name, meta)
	if type_info.kind == .Object && type_info.refc do type_info.param = fmt.aprintf("Ref(%s)", type_info.param)
	return type_info
}

builtin_name :: proc(type_name: string) -> string {
	if strings.has_prefix(type_name, "typedarray::") do return "Array"
	if strings.has_prefix(type_name, "typeddictionary::") do return "Dictionary"
	return type_name
}

map_type :: proc(type_name: string, meta: string) -> Type_Info {
	switch {
	case type_name == "bool":
		return {.Bool, "bool", "bool", false}
	case type_name == "int":
		return {.Int, "int", "i64", false}
	case type_name == "float":
		return {.Float, meta == "double" ? "f64" : "f32", "f64", false}
	case type_name == "String":
		return {.String, "string", "String", false}
	case type_name == "StringName":
		return {.StringName, "string", "StringName", false}
	case type_name == "NodePath":
		return {.NodePath, "string", "NodePath", false}
	case strings.has_prefix(type_name, "enum::") || strings.has_prefix(type_name, "bitfield::"):
		key := type_name[strings.index(type_name, "::") + 2:]
		if enum_type, ok := enum_types[key]; ok do return {.Enum, enum_type, "i64", false}
		return {.Int, "int", "i64", false}
	case strings.contains(type_name, "*"):
		return {.Pointer, "rawptr", "rawptr", false}
	case type_name == "Variant":
		return {.Builtin, "Variant", "Variant", false}
	}
	base_name := builtin_name(type_name)
	if base_name in builtin_layout || base_name in builtin_opaque do return {.Builtin, base_name, base_name, false}
	if type_name in classes {
		refcounted := is_refcounted(type_name)
		if wanted[type_name] do return {.Object, type_name, "rawptr", refcounted}
		return {.Object, refcounted ? "RefCounted" : "Object", "rawptr", refcounted}
	}
	// native structures by value never appear as method args; fall back to an opaque pointer
	return {.Pointer, "rawptr", "rawptr", false}
}

is_number :: proc(text: string) -> bool {
	_, ok := strconv.parse_f64(text)
	return ok
}

// Godot default value -> Odin default expression, or "" if not expressible.
map_default :: proc(type_info: Type_Info, raw_type: string, default_text: string) -> string {
	switch type_info.kind {
	case .Bool:
		if default_text == "true" || default_text == "false" do return default_text
	case .Int:
		if is_number(default_text) do return default_text
	case .Float:
		if default_text == "inf" do return ""
		if is_number(default_text) do return default_text
	case .Enum:
		if is_number(default_text) do return fmt.aprintf("%s(%s)", type_info.param, default_text)
	case .String, .StringName, .NodePath:
		text := default_text
		if strings.has_prefix(text, "&") do text = text[1:]
		if strings.has_prefix(text, "NodePath(") && strings.has_suffix(text, ")") do text = text[len("NodePath("):len(text) - 1]
		if len(text) >= 2 && text[0] == '"' && text[len(text) - 1] == '"' do return text
	case .Object:
		if default_text == "null" do return "{}"
	case .Builtin:
		// simple numeric constructors: Vector3(0, 1, 0), Color(1, 1, 1, 1)
		if builtin_flat[type_info.param] &&
		   strings.has_prefix(default_text, type_info.param) &&
		   strings.has_suffix(default_text, ")") {
			inner := default_text[len(type_info.param):]
			if !strings.has_prefix(inner, "(") do return ""
			inner = inner[1:len(inner) - 1]
			parts := strings.split(inner, ",")
			for part in parts do if !is_number(strings.trim_space(part)) do return ""
			return fmt.aprintf("%s{{%s}}", type_info.param, inner)
		}
	case .Pointer:
	}
	return ""
}

// Emits the conversion of parameter `name` into ptrcall slot `_aN`.
emit_arg_in :: proc(builder: ^strings.Builder, type_info: Type_Info, name: string, index: int) {
	switch type_info.kind {
	case .Bool, .Builtin, .Pointer:
		fmt.sbprintf(builder, "\t_a%d := %s\n", index, name)
	case .Int, .Enum:
		fmt.sbprintf(builder, "\t_a%d := i64(%s)\n", index, name)
	case .Float:
		fmt.sbprintf(builder, "\t_a%d := f64(%s)\n", index, name)
	case .String:
		fmt.sbprintf(builder, "\t_a%d := string_from(%s); defer String_destroy(&_a%d)\n", index, name, index)
	case .StringName:
		if type_info.param == "^StringName" {
			fmt.sbprintf(builder, "\t_a%d := %s^ // borrowed: the caller keeps it alive\n", index, name)
		} else {
			fmt.sbprintf(
				builder,
				"\t_a%d := string_name_from(%s); defer StringName_destroy(&_a%d)\n",
				index,
				name,
				index,
			)
		}
	case .NodePath:
		fmt.sbprintf(builder, "\t_a%d := node_path_from(%s); defer NodePath_destroy(&_a%d)\n", index, name, index)
	case .Object:
		fmt.sbprintf(builder, "\t_a%d := %s.ptr\n", index, name)
	}
}

// Declares `_ret` for the return slot.
emit_ret_decl :: proc(builder: ^strings.Builder, type_info: Type_Info) {
	if type_info.kind == .Builtin && type_info.param in builtin_opaque && type_info.param != "Variant" {
		fmt.sbprintf(builder, "\t_ret := %s_new0()\n", type_info.param) // default-construct (Array etc. aren't valid when zeroed)
	} else {
		fmt.sbprintf(builder, "\t_ret: %s\n", type_info.slot)
	}
}

emit_ret_out :: proc(builder: ^strings.Builder, type_info: Type_Info) {
	switch type_info.kind {
	case .Bool, .Builtin, .Pointer:
		strings.write_string(builder, "\treturn _ret\n")
	case .Int:
		strings.write_string(builder, "\treturn int(_ret)\n")
	case .Enum:
		fmt.sbprintf(builder, "\treturn %s(_ret)\n", type_info.param)
	case .Float:
		fmt.sbprintf(builder, "\treturn %s(_ret)\n", type_info.param)
	case .String:
		strings.write_string(
			builder,
			"\tdefer String_destroy(&_ret)\n\treturn string_to_odin(&_ret, context.temp_allocator)\n",
		)
	case .StringName:
		strings.write_string(
			builder,
			"\tdefer StringName_destroy(&_ret)\n\treturn string_name_to_odin(&_ret, context.temp_allocator)\n",
		)
	case .NodePath:
		strings.write_string(
			builder,
			"\tdefer NodePath_destroy(&_ret)\n\treturn node_path_to_odin(&_ret, context.temp_allocator)\n",
		)
	case .Object:
		fmt.sbprintf(builder, "\treturn transmute(%s)_ret\n", type_info.param)
	}
}

// Vararg methods: fixed arguments and `rest` become Variants, then a Variant call.
emit_vararg_body :: proc(
	builder: ^strings.Builder,
	params: []Param,
	self_ptr: string,
	has_ret: bool,
	return_info: Type_Info,
) {
	fmt.sbprintf(builder, "\t_vs := make([]Variant, %d + len(rest), context.temp_allocator)\n", len(params))
	fmt.sbprintf(builder, "\t_ps := make([]rawptr, %d + len(rest), context.temp_allocator)\n", len(params))
	for param, i in params {
		switch param.ti.kind {
		case .StringName:
			fmt.sbprintf(builder, "\t_vs[%d] = variant_string_name(%s)\n", i, param.name)
		case .NodePath:
			fmt.sbprintf(builder, "\t_vs[%d] = variant_node_path(%s)\n", i, param.name)
		case .Bool, .Int, .Float, .Enum, .String, .Builtin, .Object, .Pointer:
			fmt.sbprintf(builder, "\t_vs[%d] = to_variant(%s)\n", i, param.name)
		}
	}
	fmt.sbprintf(builder, "\tfor a, i in rest do _vs[%d + i] = variant_from_any(a)\n", len(params))
	strings.write_string(builder, "\tfor &v, i in _vs do _ps[i] = &v\n")
	strings.write_string(builder, "\t_ret: Variant\n\t_err: gdi.CallError\n")
	fmt.sbprintf(
		builder,
		"\tgdi.object_method_bind_call(_mb, %s, raw_data(_ps), i64(len(_ps)), &_ret, &_err)\n",
		self_ptr,
	)
	strings.write_string(builder, "\tfor &v in _vs do variant_destroy(&v)\n")
	strings.write_string(builder, "\tif _err.error != .OK do call_error(_err, #procedure)\n")
	if !has_ret {
		strings.write_string(builder, "\tvariant_destroy(&_ret)\n")
	} else if return_info.param == "Variant" {
		strings.write_string(builder, "\treturn _ret\n")
	} else {
		strings.write_string(builder, "\tdefer variant_destroy(&_ret)\n")
		fmt.sbprintf(builder, "\t_r, _ := from_variant(%s, &_ret)\n\treturn _r\n", return_info.param)
	}
}

Param :: struct {
	name: string,
	ti:   Type_Info,
	def:  string,
}

collect_params :: proc(args: json.Array, raw_strings := false) -> []Param {
	params := make([]Param, len(args))
	for arg, i in args {
		arg_object := jobj(arg)
		type_name := jstr(arg_object, "type")
		type_info := map_type(type_name, jstr(arg_object, "meta"))
		if raw_strings && (type_info.kind == .String || type_info.kind == .StringName || type_info.kind == .NodePath) do type_info = {.Builtin, type_name, type_name, false}
		default_text := ""
		if default_value, ok := arg_object["default_value"].(json.String); ok do default_text = map_default(type_info, type_name, default_value)
		params[i] = {safe_name(jstr(arg_object, "name")), type_info, default_text}
	}
	// Odin allows defaults anywhere, but keep them trailing so positional calls stay unambiguous.
	seen_required := false
	#reverse for &param in params {
		if param.def == "" do seen_required = true
		else if seen_required do param.def = ""
	}
	return params
}

write_params :: proc(builder: ^strings.Builder, self_decl: string, params: []Param) {
	strings.write_string(builder, self_decl)
	for param, i in params {
		if i > 0 || self_decl != "" do strings.write_string(builder, ", ")
		fmt.sbprintf(builder, "%s: %s", param.name, param.ti.param)
		if param.def != "" do fmt.sbprintf(builder, " = %s", param.def)
	}
}

write_args_array :: proc(builder: ^strings.Builder, params: []Param) -> string {
	if len(params) == 0 do return "nil"
	strings.write_string(builder, "\t_args := [?]rawptr{")
	for _, i in params {
		if i > 0 do strings.write_string(builder, ", ")
		fmt.sbprintf(builder, "&_a%d", i)
	}
	strings.write_string(builder, "}\n")
	return "&_args[0]"
}

Stats :: struct {
	classes, methods, vararg, skipped_vararg, skipped_virtual, builtin_methods, sn_overloads: int,
}
stats: Stats

gen_class_method :: proc(builder: ^strings.Builder, class_name: string, method: json.Object) {
	if jbool(method, "is_virtual") {
		stats.skipped_virtual += 1
		return
	}
	stats.methods += 1
	vararg := jbool(method, "is_vararg")
	method_name := jstr(method, "name")
	params := collect_params(jarr(method["arguments"]))
	if vararg {
		stats.vararg += 1
		for &param in params do param.def = "" // defaults before a variadic tail are not allowed
	}
	has_sn := false
	for param in params do if param.ti.kind == .StringName do has_sn = true
	if vararg || !has_sn {
		gen_class_method_proc(
			builder,
			class_name,
			method_name,
			fmt.aprintf("%s_%s", class_name, method_name),
			method,
			params,
			vararg,
		)
		return
	}
	// StringName parameters: a group of two, Odin strings (`_str`, converted per call) or interned
	// `^StringName`s (`_sn`, e.g. gd.sn("move_left"), no conversion): hot paths pass cached names.
	stats.sn_overloads += 1
	gen_class_method_proc(
		builder,
		class_name,
		method_name,
		fmt.aprintf("%s_%s_str", class_name, method_name),
		method,
		params,
		false,
	)
	sn_params := slice.clone(params)
	for &param in sn_params {
		if param.ti.kind != .StringName do continue
		param.ti = {.StringName, "^StringName", "StringName", false}
		param.def = ""
	}
	seen_required := false
	#reverse for &param in sn_params {
		if param.def == "" do seen_required = true
		else if seen_required do param.def = ""
	}
	gen_class_method_proc(
		builder,
		class_name,
		method_name,
		fmt.aprintf("%s_%s_sn", class_name, method_name),
		method,
		sn_params,
		false,
	)
	fmt.sbprintf(
		builder,
		"%s_%s :: proc {{%s_%s_str, %s_%s_sn}}\n",
		class_name,
		method_name,
		class_name,
		method_name,
		class_name,
		method_name,
	)
}

gen_class_method_proc :: proc(
	builder: ^strings.Builder,
	class_name, method_name, proc_name: string,
	method: json.Object,
	params: []Param,
	vararg: bool,
) {
	return_value := jobj(method["return_value"])
	has_ret := return_value != nil
	return_info: Type_Info
	if has_ret do return_info = ret_type(jstr(return_value, "type"), jstr(return_value, "meta"))
	is_static := jbool(method, "is_static")
	fmt.sbprintf(builder, "%s :: proc(", proc_name)
	write_params(builder, is_static ? "" : fmt.aprintf("self: %s", class_name), params)
	if vararg do strings.write_string(builder, len(params) > 0 || !is_static ? ", rest: ..any" : "rest: ..any")
	strings.write_string(builder, ")")
	if has_ret do fmt.sbprintf(builder, " -> %s", return_info.param)
	strings.write_string(builder, " {\n")
	strings.write_string(builder, "\twhen ODIN_DEBUG do check_main_thread()\n")
	strings.write_string(builder, "\t@(static) _mb: rawptr\n")
	fmt.sbprintf(
		builder,
		"\tif _mb == nil do _mb = method_bind(\"%s\", \"%s\", %d)\n",
		class_name,
		method_name,
		jint(method, "hash"),
	)
	if vararg {
		emit_vararg_body(builder, params, is_static ? "nil" : "self.ptr", has_ret, return_info)
		strings.write_string(builder, "}\n")
		return
	}
	for param, i in params do emit_arg_in(builder, param.ti, param.name, i)
	args := write_args_array(builder, params)
	if has_ret do emit_ret_decl(builder, return_info)
	fmt.sbprintf(
		builder,
		"\tgdi.object_method_bind_ptrcall(_mb, %s, %s, %s)\n",
		is_static ? "nil" : "self.ptr",
		args,
		has_ret ? "&_ret" : "nil",
	)
	if has_ret do emit_ret_out(builder, return_info)
	strings.write_string(builder, "}\n")
}

gen_builtin_method :: proc(builder: ^strings.Builder, type_name: string, variant_index: int, method: json.Object) {
	if jbool(method, "is_vararg") {
		stats.skipped_vararg += 1
		return
	}
	stats.builtin_methods += 1
	method_name := jstr(method, "name")
	params := collect_params(jarr(method["arguments"]))
	return_type := jstr(method, "return_type")
	has_ret := return_type != ""
	return_info: Type_Info
	if has_ret do return_info = ret_type(return_type, "")
	is_static := jbool(method, "is_static")
	fmt.sbprintf(builder, "%s_%s :: proc(", type_name, method_name)
	write_params(builder, is_static ? "" : fmt.aprintf("self: ^%s", type_name), params)
	strings.write_string(builder, ")")
	if has_ret do fmt.sbprintf(builder, " -> %s", return_info.param)
	strings.write_string(builder, " {\n")
	strings.write_string(builder, "\t@(static) _fp: gdi.PtrBuiltInMethod\n")
	fmt.sbprintf(
		builder,
		"\tif _fp == nil do _fp = builtin_method(gdi.VariantType(%d), \"%s\", %d)\n",
		variant_index,
		method_name,
		jint(method, "hash"),
	)
	for param, i in params do emit_arg_in(builder, param.ti, param.name, i)
	args := write_args_array(builder, params)
	if has_ret do emit_ret_decl(builder, return_info)
	fmt.sbprintf(
		builder,
		"\t_fp(%s, %s, %s, %d)\n",
		is_static ? "nil" : "self",
		args == "nil" ? "nil" : args,
		has_ret ? "&_ret" : "nil",
		len(params),
	)
	if has_ret do emit_ret_out(builder, return_info)
	strings.write_string(builder, "}\n")
}

enum_name :: proc(scope: string, name: string) -> string {
	text, _ := strings.replace_all(name, ".", "_")
	if scope == "" do return text
	return fmt.aprintf("%s_%s", scope, text)
}

emit_enum :: proc(builder: ^strings.Builder, type_name: string, enum_object: json.Object) {
	fmt.sbprintf(builder, "%s :: enum i64 {{\n", type_name)
	for value in jarr(enum_object["values"]) {
		value_object := jobj(value)
		fmt.sbprintf(builder, "\t%s = %d,\n", jstr(value_object, "name"), jint(value_object, "value"))
	}
	strings.write_string(builder, "}\n")
}

snake_field :: proc(name: string) -> string {
	return fmt.aprintf("base_%s", name)
}

variant_key :: proc(name: string) -> string {
	key, _ := strings.replace_all(strings.to_upper(name), "_", "")
	return key
}

gen_api :: proc(api: json.Object, class_list, builtin_list: []string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "// GENERATED by src/gdext/gen from extension_api.json. Do not edit.\n")
	strings.write_string(&builder, "package gdext\n\nimport \"gdi\"\n\n")
	header := jobj(api["header"])
	fmt.sbprintf(&builder, "API_VERSION :: \"%s\"\n\n", jstr(header, "version_full_name"))

	for class_value in jarr(api["classes"]) {
		class_object := jobj(class_value)
		classes[jstr(class_object, "name")] = class_object
	}
	for class_name in ([]string{"Object", "RefCounted"}) do wanted[class_name] = true
	for class_name in class_list {
		cur := class_name
		for cur != "" {
			class_object, ok := classes[cur]
			if !ok {
				fmt.eprintln("unknown class", cur)
				os.exit(1)
			}
			wanted[cur] = true
			cur = jstr(class_object, "inherits")
		}
	}

	// Variant::Type indices from the global enum.
	for enum_value in jarr(api["global_enums"]) {
		enum_object := jobj(enum_value)
		if jstr(enum_object, "name") != "Variant.Type" do continue
		for value in jarr(enum_object["values"]) {
			value_object := jobj(value)
			value_name := jstr(value_object, "name")
			if strings.has_prefix(value_name, "TYPE_") do variant_type_index[variant_key(value_name[5:])] = int(jint(value_object, "value"))
		}
	}

	// Builtin layouts (float_64 = single-precision real_t, 64-bit pointers).
	strings.write_string(&builder, "// ---- builtin types (build configuration float_64)\n\n")
	sizes: map[string]int
	for config in jarr(api["builtin_class_sizes"]) {
		class_object := jobj(config)
		if jstr(class_object, "build_configuration") != "float_64" do continue
		for size_value in jarr(class_object["sizes"]) {
			size_object := jobj(size_value)
			sizes[jstr(size_object, "name")] = int(jint(size_object, "size"))
		}
	}
	for config in jarr(api["builtin_class_member_offsets"]) {
		class_object := jobj(config)
		if jstr(class_object, "build_configuration") != "float_64" do continue
		for class_value in jarr(class_object["classes"]) {
			class_layout := jobj(class_value)
			name := jstr(class_layout, "name")
			builtin_layout[name] = true
			builtin_flat[name] = true
			fmt.sbprintf(&builder, "%s :: struct {{\n", name)
			for member in jarr(class_layout["members"]) {
				member_object := jobj(member)
				meta := jstr(member_object, "meta")
				type_name := meta == "float" ? "f32" : meta == "int32" ? "i32" : meta
				if type_name == meta do builtin_flat[name] = false
				fmt.sbprintf(
					&builder,
					"\t%s: %s, // offset %d\n",
					jstr(member_object, "member"),
					type_name,
					jint(member_object, "offset"),
				)
			}
			fmt.sbprintf(&builder, "}\n#assert(size_of(%s) == %d)\n", name, sizes[name])
		}
	}
	SKIP :: []string{"Nil", "bool", "int", "float", "Object"}
	for class_value in jarr(api["builtin_classes"]) {
		name := jstr(jobj(class_value), "name")
		if slice.contains(SKIP, name) || name in builtin_layout do continue
		builtin_opaque[name] = sizes[name]
		fmt.sbprintf(&builder, "%s :: struct #align(8) {{ _opaque: [%d]u8 }}\n", name, sizes[name])
	}
	builtin_opaque["Variant"] = sizes["Variant"]
	fmt.sbprintf(&builder, "Variant :: struct #align(8) {{ _opaque: [%d]u8 }}\n\n", sizes["Variant"])

	// Enums: global + wanted classes. Register names first so method signatures can use them.
	for enum_value in jarr(api["global_enums"]) {
		enum_object := jobj(enum_value)
		global_enum_name := jstr(enum_object, "name")
		enum_types[global_enum_name] = enum_name("", global_enum_name)
	}
	for class_name in wanted {
		class_object := classes[class_name]
		for enum_value in jarr(class_object["enums"]) {
			enum_local_name := jstr(jobj(enum_value), "name")
			enum_types[fmt.aprintf("%s.%s", class_name, enum_local_name)] = enum_name(class_name, enum_local_name)
		}
	}
	strings.write_string(&builder, "// ---- global enums\n\n")
	for enum_value in jarr(api["global_enums"]) {
		enum_object := jobj(enum_value)
		emit_enum(&builder, enum_name("", jstr(enum_object, "name")), enum_object)
	}

	// Opaque builtin constructors / destructors.
	strings.write_string(&builder, "\n// ---- builtin constructors and destructors\n\n")
	for class_value in jarr(api["builtin_classes"]) {
		class_object := jobj(class_value)
		name := jstr(class_object, "name")
		if !(name in builtin_opaque) do continue
		variant_index := variant_type_index[variant_key(name)]
		for ctor in jarr(class_object["constructors"]) {
			ctor_object := jobj(ctor)
			idx := jint(ctor_object, "index")
			params := collect_params(jarr(ctor_object["arguments"]), raw_strings = true)
			for &param in params do param.def = ""
			fmt.sbprintf(&builder, "%s_new%d :: proc(", name, idx)
			write_params(&builder, "", params)
			fmt.sbprintf(&builder, ") -> %s {{\n", name)
			strings.write_string(&builder, "\t@(static) _fp: gdi.PtrConstructor\n")
			fmt.sbprintf(
				&builder,
				"\tif _fp == nil do _fp = gdi.variant_get_ptr_constructor(gdi.VariantType(%d), %d)\n",
				variant_index,
				idx,
			)
			for param, i in params do emit_arg_in(&builder, param.ti, param.name, i)
			args := write_args_array(&builder, params)
			fmt.sbprintf(&builder, "\t_ret: %s\n\t_fp(&_ret, %s)\n\treturn _ret\n}}\n", name, args)
		}
		if jbool(class_object, "has_destructor") {
			fmt.sbprintf(&builder, "%s_destroy :: proc(self: ^%s) {{\n", name, name)
			strings.write_string(&builder, "\t@(static) _fp: gdi.PtrDestructor\n")
			fmt.sbprintf(
				&builder,
				"\tif _fp == nil do _fp = gdi.variant_get_ptr_destructor(gdi.VariantType(%d))\n",
				variant_index,
			)
			strings.write_string(&builder, "\t_fp(self)\n}\n")
		}
	}

	// Builtin methods for the whitelisted builtins.
	strings.write_string(&builder, "\n// ---- builtin methods\n\n")
	for class_value in jarr(api["builtin_classes"]) {
		class_object := jobj(class_value)
		name := jstr(class_object, "name")
		if !slice.contains(builtin_list, name) do continue
		variant_index := variant_type_index[variant_key(name)]
		for method in jarr(class_object["methods"]) do gen_builtin_method(&builder, name, variant_index, jobj(method))
	}

	// Classes.
	names := make([dynamic]string)
	for class_name in wanted do append(&names, class_name)
	slice.sort(names[:])
	singletons: map[string]bool
	for singleton in jarr(api["singletons"]) do singletons[jstr(jobj(singleton), "name")] = true

	for class_name in names {
		stats.classes += 1
		class_object := classes[class_name]
		fmt.sbprintf(&builder, "\n// ---- class %s\n\n", class_name)
		parent := jstr(class_object, "inherits")
		if parent == "" {
			fmt.sbprintf(&builder, "%s :: struct {{ ptr: rawptr }}\n", class_name)
		} else {
			fmt.sbprintf(&builder, "%s :: struct {{ using %s: %s }}\n", class_name, snake_field(parent), parent)
		}
		fmt.sbprintf(&builder, "%s_CLASS :: \"%s\"\n", class_name, class_name)
		if jbool(class_object, "is_instantiable") && !singletons[class_name] {
			type_name := is_refcounted(class_name) ? fmt.aprintf("Ref(%s)", class_name) : class_name
			fmt.sbprintf(
				&builder,
				"%s_new :: proc() -> %s {{ return transmute(%s)construct_object(\"%s\") }}\n",
				class_name,
				type_name,
				type_name,
				class_name,
			)
		}
		if singletons[class_name] {
			fmt.sbprintf(&builder, "%s_singleton :: proc() -> %s {{\n", class_name, class_name)
			strings.write_string(&builder, "\t@(static) _s: rawptr\n")
			fmt.sbprintf(&builder, "\tif _s == nil do _s = get_singleton(\"%s\")\n", class_name)
			fmt.sbprintf(&builder, "\treturn transmute(%s)_s\n}}\n", class_name)
		}
		for constant in jarr(class_object["constants"]) {
			constant_object := jobj(constant)
			fmt.sbprintf(
				&builder,
				"%s_%s :: %d\n",
				class_name,
				jstr(constant_object, "name"),
				jint(constant_object, "value"),
			)
		}
		for enum_value in jarr(class_object["enums"]) {
			enum_object := jobj(enum_value)
			emit_enum(&builder, enum_name(class_name, jstr(enum_object, "name")), enum_object)
		}
		for method in jarr(class_object["methods"]) do gen_class_method(&builder, class_name, jobj(method))
	}
	return strings.to_string(builder)
}

read_list :: proc(path: string) -> (class_names, builtin_names: []string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", path)
		os.exit(1)
	}
	class_list := make([dynamic]string)
	builtin_list := make([dynamic]string)
	section := ""
	for line in strings.split_lines(string(data)) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || trimmed[0] == '#' do continue
		if trimmed[0] == '[' {
			section = trimmed
			continue
		}
		if section == "[classes]" do append(&class_list, trimmed)
		else if section == "[builtins]" do append(&builtin_list, trimmed)
	}
	return class_list[:], builtin_list[:]
}

write_file :: proc(path: string, text: string) {
	if err := os.write_entire_file(path, transmute([]u8)text); err != nil {
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
	class_names, builtin_names := read_list(list_path)

	write_file(fmt.aprintf("%s/gdi/gdi.gen.odin", out_dir), gen_interface(iface))
	write_file(fmt.aprintf("%s/api.gen.odin", out_dir), gen_api(api, class_names, builtin_names))
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
