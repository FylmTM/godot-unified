// The editor's help for extension classes: every bind_* proc records what it bound, with its types and the `doc`
// text it was given, and load_docs turns that into Godot's class reference XML at the EDITOR init level. A member
// can't be bound without its doc being where it is bound.
package gdext

import "core:fmt"
import "core:strings"
import "unified:gdext/gdi"

// One member a bind_* proc registered on a class, as the editor's help shows it. A property's get_/set_ methods are
// its accessors (not listed).
Bound :: struct {
	kind:      Bound_Kind,
	name:      string,
	doc:       string,
	type:      Doc_Type, // a method's result (type "void": none), a property's type
	value:     i64, // a constant's
	enum_name: string, // a constant's enum ("": none)
	args:      []Doc_Arg, // a method's or a signal's
	static:    bool,
}

// What a Bound member is: a method, a property's accessor (get_/set_, left out of the help), a property, a signal or
// an integer constant.
Bound_Kind :: enum u8 {
	Method,
	Accessor,
	Property,
	Signal,
	Constant,
}

// A type as the class reference names it: "int", "Vector3", a class, "Node[]" (a typed Array), and an int's enum.
Doc_Type :: struct {
	name:      string,
	enum_name: string,
}

// One argument of a bound method or signal, as the class reference shows it.
Doc_Arg :: struct {
	name: string,
	type: Doc_Type,
}

// The class reference's name for a Variant type, as Godot names it ("int", "Vector2", "Dictionary"; NIL: Variant).
variant_type_name :: proc(kind: gdi.VariantType, allocator := context.temp_allocator) -> string {
	if kind == .NIL do return "Variant"
	name: String
	gdi.variant_get_type_name(kind, &name)
	defer String_destroy(&name)
	return string_to_odin(&name, allocator)
}

// How the class reference types an argument, a result or a property (cloned: the class keeps it).
@(private)
doc_type :: proc(arg: Dynamic_Arg) -> Doc_Type {
	#partial switch arg.type {
	case .OBJECT:
		return {strings.clone(arg.class_name != "" ? arg.class_name : "Object"), ""}
	case .INT:
		return {"int", strings.clone(arg.class_name)}
	case .ARRAY:
		if arg.class_name != "" do return {fmt.aprintf("%s[]", arg.class_name), ""}
	}
	return {variant_type_name(arg.type, context.allocator), ""}
}

@(private)
record_bound :: proc(cls: ^Class, bound: Bound) {
	bound := bound
	bound.name = strings.clone(bound.name)
	bound.doc = strings.clone(bound.doc)
	append(&cls.bound, bound)
}

@(private)
record_args :: proc(args: []Dynamic_Arg) -> []Doc_Arg {
	out := make([]Doc_Arg, len(args))
	for arg, i in args do out[i] = {strings.clone(arg.name), doc_type(arg)}
	return out
}

@(private)
bound_free :: proc(bound: ^Bound) {
	delete(bound.name)
	delete(bound.doc)
	delete(bound.enum_name)
	doc_type_free(bound.type)
	for arg in bound.args {
		delete(arg.name)
		doc_type_free(arg.type)
	}
	delete(bound.args)
}

@(private)
doc_type_free :: proc(type: Doc_Type) {
	if type.name != "int" && type.name != "void" do delete(type.name)
	delete(type.enum_name)
}

// Marks the methods a property reads and writes through as its accessors.
@(private)
record_accessors :: proc(cls: ^Class, getter, setter: string) {
	for &bound in cls.bound {
		if bound.kind == .Method && (bound.name == getter || (setter != "" && bound.name == setter)) {
			bound.kind = .Accessor
		}
	}
}

// Loads every registered class's reference into the editor's help (call at the EDITOR init level; a game, with no
// editor, skips it). A class's `doc_brief` and `doc`, then each member's `doc` from where it was bound.
load_docs :: proc() {
	if gdi.editor_help_load_xml_from_utf8_chars_and_len == nil do return
	for cls in registered {
		xml := class_docs_xml(cls)
		gdi.editor_help_load_xml_from_utf8_chars_and_len(
			strings.clone_to_cstring(xml, context.temp_allocator),
			gdi.Int(len(xml)),
		)
	}
}

// A class's reference in Godot's class reference XML.
class_docs_xml :: proc(cls: ^Class) -> string {
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&builder,
		"<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<class name=\"%s\" inherits=\"%s\">\n",
		cls.name,
		cls.parent,
	)
	fmt.sbprintf(&builder, "\t<brief_description>%s</brief_description>\n", cls.doc_brief)
	fmt.sbprintf(&builder, "\t<description>%s</description>\n\t<tutorials>\n\t</tutorials>\n", cls.doc)
	section :: proc(builder: ^strings.Builder, cls: ^Class, kind: Bound_Kind, tag: string) {
		any_bound := false
		for bound in cls.bound do any_bound ||= bound.kind == kind
		if !any_bound do return
		fmt.sbprintf(builder, "\t<%ss>\n", tag)
		for bound in cls.bound {
			if bound.kind != kind do continue
			switch kind {
			case .Method, .Signal:
				qualifiers := bound.static ? " qualifiers=\"static\"" : ""
				fmt.sbprintf(builder, "\t\t<%s name=\"%s\"%s>\n", tag, bound.name, qualifiers)
				if kind == .Method do fmt.sbprintf(builder, "\t\t\t<return %s />\n", type_attributes(bound.type))
				for arg, i in bound.args {
					fmt.sbprintf(
						builder,
						"\t\t\t<param index=\"%d\" name=\"%s\" %s />\n",
						i,
						arg.name,
						type_attributes(arg.type),
					)
				}
				fmt.sbprintf(builder, "\t\t\t<description>%s</description>\n\t\t</%s>\n", bound.doc, tag)
			case .Property:
				fmt.sbprintf(
					builder,
					"\t\t<member name=\"%s\" %s>%s</member>\n",
					bound.name,
					type_attributes(bound.type),
					bound.doc,
				)
			case .Constant:
				enum_attribute := bound.enum_name != "" ? fmt.tprintf(" enum=\"%s\"", bound.enum_name) : ""
				fmt.sbprintf(
					builder,
					"\t\t<constant name=\"%s\" value=\"%d\"%s>%s</constant>\n",
					bound.name,
					bound.value,
					enum_attribute,
					bound.doc,
				)
			case .Accessor:
			}
		}
		fmt.sbprintf(builder, "\t</%ss>\n", tag)
	}
	section(&builder, cls, .Method, "method")
	section(&builder, cls, .Property, "member")
	section(&builder, cls, .Signal, "signal")
	section(&builder, cls, .Constant, "constant")
	strings.write_string(&builder, "</class>\n")
	return strings.to_string(builder)
}

@(private)
type_attributes :: proc(type: Doc_Type) -> string {
	if type.enum_name != "" do return fmt.tprintf("type=\"%s\" enum=\"%s\"", type.name, type.enum_name)
	return fmt.tprintf("type=\"%s\"", type.name)
}
