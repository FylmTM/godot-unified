// The editor's help for the classes unified:godot registers (Godot's class reference XML, loaded at the EDITOR init
// level): UnifiedSession, UnifiedView, UnifiedMultiView, UnifiedEvent, UnifiedCommand and the game's event and
// command classes (sim_classes.odin), so the editor's help and autocompletion say what each one does.
package godot

import "core:fmt"
import "core:strings"
import gd "unified:gdext"

@(private)
Doc_Method :: struct {
	name, ret, params, text: string, // params: "name:Type, name:Type"
}

@(private)
Doc_Member :: struct {
	name, type, text: string,
}

@(private)
Doc_Class :: struct {
	name, inherits, brief, text: string,
	methods:                     []Doc_Method,
	members:                     []Doc_Member,
	signals:                     []Doc_Method, // ret unused
	constants:                   []Doc_Member, // type: the value; enum EventState
}

@(private)
LIBRARY_DOCS := []Doc_Class {
	{
		name = "UnifiedSession",
		inherits = "Node",
		brief = "Runs a unified session (single player, host or join) and shows it: views, events, commands.",
		text = "One per app. The session runs the game's deterministic sim on its own thread; this node takes the newest frame every process step (at priority -1000, before every other node), moves the scene views under [member view_root], fills the MultiMesh views, and routes the sim's events to their views and to [signal sim_event]. The game's extension decides what the views are (src/godot/SPEC.md). Reach it typed: [code]@onready var session: UnifiedSession = %UnifiedSession[/code].",
		methods = {
			{"start_single", "bool", "", "Starts a single player session."},
			{
				"host_online",
				"bool",
				"",
				"Hosts an online session through the game's transport; [signal lobby_code] gives the code to share.",
			},
			{
				"host_direct",
				"bool",
				"port:int",
				"Hosts on a UDP port (LAN); 127.0.0.1 only when the process got [code]--local-net[/code].",
			},
			{"join_online", "bool", "code:String", "Joins an online session by its lobby code."},
			{"join_direct", "bool", "address:String", "Joins a directly hosted session at [code]host:port[/code]."},
			{
				"leave",
				"void",
				"",
				"Ends the session: it says goodbye on its own thread. A start right after waits for it.",
			},
			{
				"send_command",
				"bool",
				"command:UnifiedCommand",
				"Sends one of the game's commands (make one with its class, e.g. [code]CommandDrop.new()[/code]); the sim gets it exactly once. False, with an error, when it can't be sent.",
			},
			{
				"set_input_value",
				"void",
				"name:StringName, value:Variant",
				"A value only scripts know (a camera's look direction: Vector3, Vector2, float or bool) that the game's input sampling reads by name.",
			},
			{"constants", "Dictionary", "", "The game's constants for scripts, plus [code]tick_hz[/code]."},
			{"set_player_name", "void", "name:String", "The name the next session shows to other players."},
			{"get_status", "String", "", "idle, connecting, connected, failed or disconnected."},
			{"is_running", "bool", "", "A session is running."},
			{"get_tick", "int", "", "The newest tick shown."},
			{"toggle_devui", "void", "", "Shows or hides the dev UI (F1)."},
			{"is_devui_visible", "bool", "", "The dev UI is shown."},
		},
		members = {
			{"view_root", "Node", "Where scene views are made, as its children."},
			{"seed", "int", "The next session's seed."},
			{"ticks", "int", "The next session's length in ticks (0: endless)."},
		},
		signals = {
			{
				"status_changed",
				"",
				"status:String, detail:String",
				"The session's status changed (idle, connecting, connected, failed, disconnected).",
			},
			{"lobby_code", "", "code:String", "The code other players join with."},
			{"desync", "", "tick:int, detail:String", "The players' checksums of [param tick] differ."},
			{
				"sim_event",
				"",
				"event:UnifiedEvent, state:int",
				"Every sim event in every state: EVENT_EMITTED once, then EVENT_CONFIRMED or EVENT_CANCELLED once. Its subject's view gets it first ([code]_sim_event(event, state)[/code]).",
			},
		},
		constants = {
			{
				"EVENT_EMITTED",
				"0",
				"The first time any simulation of its tick produced it (a prediction, or the verified tick): effects and sounds.",
			},
			{"EVENT_CONFIRMED", "1", "Its tick is verified: what must be final (score, banners)."},
			{"EVENT_CANCELLED", "2", "A re-simulation no longer produces it: undo its effect."},
		},
	},
	{
		name = "UnifiedView",
		inherits = "Node",
		brief = "Marks a scene as the view of one kind of the game's scene views.",
		text = "A direct child of the scene's root. [code]uni bake[/code] indexes the scenes by it; the host sets [member entity] and [member player] when it makes the view. The root may be a Node3D (position and rotation), a Node2D (position and rotation) or anything else (a Control HUD: data only); its script may define [code]_sim_update(position, yaw_or_rotation, alpha)[/code] and [code]_sim_event(event: UnifiedEvent, state: int)[/code], and properties named after the fields of the view's data.",
		members = {
			{"kind", "String", "The view kind (the game's View enum member, lowercased), set in the scene."},
			{"entity", "int", "The id the game's events carry for this view (0: none)."},
			{"player", "int", "The player this view shows (-1: none)."},
		},
		signals = {
			{
				"despawned",
				"",
				"",
				"The view's key is gone from the sim: it lingers 0.25 s (an exit animation), then is freed.",
			},
			{"revived", "", "", "A rollback brought the view back while it lingered: undo the exit animation."},
		},
	},
	{
		name = "UnifiedMultiView",
		inherits = "Node",
		brief = "Makes its parent MultiMeshInstance3D or MultiMeshInstance2D show one kind of the game's MultiMesh items.",
		text = "The host owns the MultiMesh's instance count and buffer: position and rotation interpolated between ticks, scale, color ([code]use_colors[/code]) and custom data ([code]use_custom_data[/code]).",
		members = {
			{"kind", "String", "The kind (the game's Multi enum member, lowercased)."},
			{
				"smooth",
				"bool",
				"Rollback corrections glide like a scene view's instead of popping (state per instance).",
			},
		},
	},
	{
		name = "UnifiedEvent",
		inherits = "RefCounted",
		brief = "One of the game's sim events: the base of its event classes.",
		text = "Each kind of the game's event union is a class extending this one, named Event + its type name (Rock_Hit: [code]EventRockHit[/code]), with a property per field.",
		members = {{"tick", "int", "The tick that produced it."}},
	},
	{
		name = "UnifiedCommand",
		inherits = "RefCounted",
		brief = "One of the game's commands: the base of its command classes.",
		text = "Each kind of the game's command union is a class extending this one, named Command + its type name without Cmd_ (Cmd_Drop: [code]CommandDrop[/code]), with a property per field. Make one, set its fields, and send it with [method UnifiedSession.send_command].",
	},
}

@(private)
doc_params :: proc(builder: ^strings.Builder, params: string) {
	if params == "" do return
	for param, i in strings.split(params, ", ", context.temp_allocator) {
		colon := strings.index_byte(param, ':')
		fmt.sbprintf(
			builder,
			"\t\t\t<param index=\"%d\" name=\"%s\" type=\"%s\" />\n",
			i,
			param[:colon],
			param[colon + 1:],
		)
	}
}

@(private)
doc_xml :: proc(class: Doc_Class) -> string {
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&builder,
		"<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<class name=\"%s\" inherits=\"%s\">\n",
		class.name,
		class.inherits,
	)
	fmt.sbprintf(&builder, "\t<brief_description>%s</brief_description>\n", class.brief)
	fmt.sbprintf(&builder, "\t<description>%s</description>\n\t<tutorials>\n\t</tutorials>\n", class.text)
	if len(class.methods) > 0 {
		strings.write_string(&builder, "\t<methods>\n")
		for method in class.methods {
			fmt.sbprintf(&builder, "\t\t<method name=\"%s\">\n\t\t\t<return type=\"%s\" />\n", method.name, method.ret)
			doc_params(&builder, method.params)
			fmt.sbprintf(&builder, "\t\t\t<description>%s</description>\n\t\t</method>\n", method.text)
		}
		strings.write_string(&builder, "\t</methods>\n")
	}
	if len(class.members) > 0 {
		strings.write_string(&builder, "\t<members>\n")
		for member in class.members {
			fmt.sbprintf(
				&builder,
				"\t\t<member name=\"%s\" type=\"%s\">%s</member>\n",
				member.name,
				member.type,
				member.text,
			)
		}
		strings.write_string(&builder, "\t</members>\n")
	}
	if len(class.signals) > 0 {
		strings.write_string(&builder, "\t<signals>\n")
		for signal in class.signals {
			fmt.sbprintf(&builder, "\t\t<signal name=\"%s\">\n", signal.name)
			doc_params(&builder, signal.params)
			fmt.sbprintf(&builder, "\t\t\t<description>%s</description>\n\t\t</signal>\n", signal.text)
		}
		strings.write_string(&builder, "\t</signals>\n")
	}
	if len(class.constants) > 0 {
		strings.write_string(&builder, "\t<constants>\n")
		for constant in class.constants {
			fmt.sbprintf(
				&builder,
				"\t\t<constant name=\"%s\" value=\"%s\" enum=\"EventState\">%s</constant>\n",
				constant.name,
				constant.type,
				constant.text,
			)
		}
		strings.write_string(&builder, "\t</constants>\n")
	}
	strings.write_string(&builder, "</class>\n")
	return strings.to_string(builder)
}

// The Godot type name of a Variant type, for a member's docs.
@(private)
doc_type :: proc(kind: Sim_Field) -> string {
	#partial switch kind.kind {
	case .INT:
		return "int"
	case .FLOAT:
		return "float"
	case .BOOL:
		return "bool"
	case .STRING_NAME:
		return "StringName"
	case .VECTOR2:
		return "Vector2"
	case .VECTOR3:
		return "Vector3"
	case .COLOR:
		return "Color"
	case .ARRAY:
		return "Array"
	case .DICTIONARY:
		return "Dictionary"
	}
	return "Variant"
}

// Loads every class's docs into the editor's help (EDITOR init level).
load_docs :: proc() {
	for class in LIBRARY_DOCS do gd.load_class_docs(doc_xml(class))
	for sim_class in sim_classes {
		members := make([]Doc_Member, len(sim_class.fields), context.temp_allocator)
		for field, i in sim_class.fields {
			members[i] = {
				field.name,
				doc_type(field),
				fmt.tprintf("The field [code]%s[/code] (Odin %v).", field.name, field.type.id),
			}
		}
		what := sim_class.is_event ? "event" : "command"
		gd.load_class_docs(
			doc_xml(
				{
					name = sim_class.name,
					inherits = sim_class.parent,
					brief = fmt.tprintf("The game's %s %v.", what, sim_class.type.id),
					text = sim_class.is_event ? "Reaches views ([code]_sim_event[/code]) and [signal UnifiedSession.sim_event] in each of its states." : "Set its fields and send it with [method UnifiedSession.send_command].",
					members = members,
				},
			),
		)
	}
}
