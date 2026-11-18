// The editor's help for the classes unified:godot registers (Godot's class reference XML, loaded at the EDITOR init
// level): UnifiedSession, UnifiedView, UnifiedMultiView, UnifiedEvent, UnifiedCommand, the Unified singleton and the
// game's event, command, data, constants and enum classes (sim_classes.odin, data.odin), so the editor's help and
// autocompletion say what each one does.
#+private
package godot

import "core:fmt"
import "core:strings"
import gd "unified:gdext"

Doc_Method :: struct {
	name, ret, params, text: string, // params: "name:Type, name:Type"
}

Doc_Member :: struct {
	name, type, text: string,
}

Doc_Class :: struct {
	name, inherits, brief, text: string,
	methods:                     []Doc_Method,
	members:                     []Doc_Member,
	signals:                     []Doc_Method, // ret unused
	constants:                   []Doc_Member, // type: the value
	constants_enum:              string, // the enum the constants belong to ("": none)
}

LIBRARY_DOCS := []Doc_Class {
	{
		name           = "UnifiedSession",
		inherits       = "Node",
		brief          = "Runs a unified session (single player, host or join) and shows it: views, events, commands.",
		text           = "One per app. The session runs the game's deterministic sim on its own thread; this node takes the newest frame every process step (at priority -1000, before every other node), moves the scene views under [member view_root], fills the MultiMesh views, and routes the sim's events to their views and to [signal sim_event]. The game's extension decides what the views are (src/godot/SPEC.md). Reach it typed: [code]@onready var session: UnifiedSession = %UnifiedSession[/code].",
		methods        = {
			{"start_single", "bool", "", "Starts a single player session."},
			{
				"host_online",
				"bool",
				"",
				"Hosts an online session through the game's lobby service; [signal lobby_code] gives the code to share.",
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
			{"set_player_name", "void", "name:String", "The name the next session shows to other players."},
			{"get_status", "String", "", "idle, connecting, connected, failed or disconnected."},
			{"is_running", "bool", "", "A session is running."},
			{"get_tick", "int", "", "The newest tick shown."},
			{
				"get_local_player",
				"int",
				"",
				"The local player's key at the shown tick (0 until it joins). A player's key is the same while they are in the session, whatever slot they hold.",
			},
			{"get_players", "Array", "", "The keys of the players present at the shown tick, in slot order."},
			{
				"get_known_players",
				"Array",
				"",
				"The keys of every player the session remembers at the shown tick, present or not.",
			},
			{
				"get_player_slot",
				"int",
				"player:int",
				"The slot (input index) [param player] holds at the shown tick; -1 when absent.",
			},
			{"is_player_present", "bool", "player:int", "[param player] holds a slot at the shown tick."},
			{
				"get_player_name",
				"String",
				"player:int",
				"The name [param player] goes by in the session (\"\" when unknown); still answers after they left.",
			},
			{
				"get_player_platform",
				"String",
				"player:int",
				"The platform of the account the lobby's link vouched for (\"eos\"); empty on LAN, in single player and in replays.",
			},
			{
				"get_player_platform_id",
				"String",
				"player:int",
				"The account id the lobby's link vouched for (EOS: the product user id); empty on LAN, in single player and in replays.",
			},
			{
				"take_sync_stats",
				"Dictionary",
				"",
				"The main thread's view-sync cost since the last call, then counts anew: frames, fresh (frames with a new tick), events (deliveries), and microseconds summed over the frames: scene_us, multi_build_us, multi_upload_us, delivery_us, total_us; total_max_us is the slowest frame's.",
			},
			{"toggle_devui", "void", "", "Shows or hides the dev UI (F1)."},
			{"is_devui_visible", "bool", "", "The dev UI is shown."},
		},
		members        = {
			{
				"view_root",
				"Node",
				"Where scene views are made, as its children: set in the inspector or from a script; until it is set, the session's parent. Set it to null for no scene views.",
			},
			{"seed", "int", "The next session's seed."},
			{"ticks", "int", "The next session's length in ticks (0: endless)."},
			{
				"game_input",
				"bool",
				"Off, the game's input helpers read nothing (a pause menu, a chat field: their keys and clicks don't reach the sim); input values still flow. When it is turned back on, an action still held counts only once it is released.",
			},
		},
		signals        = {
			{
				"status_changed",
				"",
				"status:String, detail:String",
				"The session's status changed (idle, connecting, connected, failed, disconnected).",
			},
			{"lobby_code", "", "code:String", "The code other players join with."},
			{"desync", "", "tick:int, detail:String", "The players' checksums of [param tick] differ."},
			{"roster_changed", "", "", "A player's name, connection or account changed (the get_player_* getters)."},
			{
				"sim_event",
				"",
				"event:UnifiedEvent, state:int",
				"Every sim event in every state: EVENT_EMITTED once, then EVENT_CONFIRMED or EVENT_CANCELLED once. Its subject's view gets it first ([code]_sim_event(event, state)[/code]).",
			},
		},
		constants_enum = "EventState",
		constants      = {
			{
				"EVENT_EMITTED",
				"0",
				"The first time any simulation of its tick produced it (a prediction, or the verified tick): effects and sounds.",
			},
			{"EVENT_CONFIRMED", "1", "Its tick is verified: what must be final (score, banners)."},
			{
				"EVENT_CANCELLED",
				"2",
				"A re-simulation no longer produces it: undo the effect its EVENT_EMITTED started (the same [member UnifiedEvent.id]).",
			},
		},
	},
	{
		name     = "UnifiedView",
		inherits = "Node",
		brief    = "Marks a scene as the view of one kind of the game's scene views.",
		text     = "A direct child of the scene's root. [code]uni bake[/code] indexes the scenes by it; the host keeps [member entity] and [member player] current. The root may be a Node3D (position and rotation), a Node2D (position and rotation) or anything else (data only); its script may define [code]_sim_update(position, yaw_or_rotation, alpha)[/code], [code]_sim_event(event: UnifiedEvent, state: int)[/code], properties named after the fields of the view's data, and the lifecycle callbacks [code]_sim_despawned()[/code] (its key is gone: it lingers [member linger_s], no longer posed, then is freed), [code]_sim_revived()[/code] (a rollback brought it back while it lingered) and [code]_sim_cancelled()[/code] (a rollback removed it before its spawn tick was verified: freed at once).",
		members  = {
			{"kind", "String", "The view kind (the game's View enum member, lowercased), set in the scene."},
			{"entity", "int", "The id the game's events carry for this view (unset in the game: its key)."},
			{"player", "int", "The key of the player this view shows (0: none)."},
			{"linger_s", "float", "How long the view stays once its key is gone (an exit animation), in seconds."},
		},
	},
	{
		name     = "Unified",
		inherits = "Object",
		brief    = "The engine singleton for the game's session data, its constants and the session.",
		text     = "[member data] holds the game's session data, [member constants] its constants, [member session] the active [UnifiedSession].",
		members  = {
			{"data", "UnifiedData", "The game's session data, one typed object per type."},
			{"constants", "UnifiedConstants", "The game's constants."},
			{"session", "UnifiedSession", "The active session node (null: none)."},
			{"tick_hz", "int", "The sim's ticks per second."},
			{
				"view_scale",
				"float",
				"View units per sim unit (the game's Glue.view_scale; 1 unless set): positions arrive scaled already; multiply a sim size (a radius from the constants) by it.",
			},
		},
	},
	{
		name     = "UnifiedData",
		inherits = "Object",
		brief    = "The game's session data: [code]Unified.data[/code].",
		text     = "A typed property per type of the game's session data ([code]Data_Hud[/code]: [code]Unified.data.hud[/code], a [code]DataHud[/code] with a [code]changed[/code] signal), set from the newest tick and back to zero when a session ends.",
	},
	{
		name     = "UnifiedMultiView",
		inherits = "Node",
		brief    = "Makes its parent MultiMeshInstance3D or MultiMeshInstance2D show one kind of the game's MultiMesh items.",
		text     = "The host owns the MultiMesh's instance count and buffer: position and rotation interpolated between ticks, scale, color ([code]use_colors[/code]) and custom data ([code]use_custom_data[/code]).",
		members  = {
			{"kind", "String", "The kind (the game's MultiView enum member, lowercased)."},
			{
				"smooth",
				"bool",
				"Rollback corrections glide like a scene view's instead of popping (state per instance).",
			},
		},
	},
	{
		name     = "UnifiedEvent",
		inherits = "RefCounted",
		brief    = "One of the game's sim events: the base of its event classes.",
		text     = "Each kind of the game's event union is a class extending this one, named Event + its type name (Rock_Hit: [code]EventRockHit[/code]), with a property per field.",
		members  = {
			{"tick", "int", "The tick that produced it."},
			{"kind", "String", "Its kind: the type name without Event_, lowercased."},
			{
				"id",
				"int",
				"The same in its EVENT_EMITTED and in its EVENT_CONFIRMED or EVENT_CANCELLED (each state is a new object): remember what an effect started by it, undo it on EVENT_CANCELLED, forget it on EVENT_CONFIRMED. Never repeats in the process; an event cancelled and produced again later is a new one.",
			},
		},
	},
	{
		name     = "UnifiedCommand",
		inherits = "RefCounted",
		brief    = "One of the game's commands: the base of its command classes.",
		text     = "Each kind of the game's command union is a class extending this one, named Command + its type name without Cmd_ (Cmd_Drop: [code]CommandDrop[/code]), with a property per field. Make one, set its fields, and send it with [method UnifiedSession.send_command].",
	},
}

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
				"\t\t<constant name=\"%s\" value=\"%s\"%s>%s</constant>\n",
				constant.name,
				constant.type,
				class.constants_enum != "" ? fmt.tprintf(" enum=\"%s\"", class.constants_enum) : "",
				constant.text,
			)
		}
		strings.write_string(&builder, "\t</constants>\n")
	}
	strings.write_string(&builder, "</class>\n")
	return strings.to_string(builder)
}

// The Godot type name of a Variant type, for a member's docs.
doc_type :: proc(kind: Sim_Field) -> string {
	#partial switch kind.kind {
	case .INT:
		return "int"
	case .FLOAT:
		return "float"
	case .BOOL:
		return "bool"
	case .STRING:
		return "String"
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
	case:
		if _, is_builtin := gd.builtin_variant_type(kind.type.id); is_builtin do return fmt.tprint(kind.type.id) // Vector4, Quaternion...
	}
	return "Variant"
}

// A struct's fields as doc members.
doc_members :: proc(fields: []Sim_Field) -> []Doc_Member {
	members := make([]Doc_Member, len(fields), context.temp_allocator)
	for field, i in fields {
		members[i] = {
			field.name,
			doc_type(field),
			fmt.tprintf("The field [code]%s[/code] (Odin %v).", field.name, field.type.id),
		}
	}
	return members
}

// Loads every class's docs into the editor's help (EDITOR init level).
load_docs :: proc() {
	for problem in docs_problems() do gd.print_error(problem)
	for class in LIBRARY_DOCS do gd.load_class_docs(doc_xml(class))
	for sim_class in sim_classes {
		what := sim_class.is_event ? "event" : "command"
		gd.load_class_docs(doc_xml({
				name     = sim_class.name,
				inherits = sim_class.parent,
				brief    = fmt.tprintf("The game's %s %v.", what, sim_class.type.id),
				text     = sim_class.is_event ? "Reaches views ([code]_sim_event[/code]) and [signal UnifiedSession.sim_event] in each of its states." : "Set its fields and send it with [method UnifiedSession.send_command].",
				members  = doc_members(sim_class.fields),
			}))
	}
	for data_class in data_classes() {
		is_constants := data_class == D.constants
		gd.load_class_docs(doc_xml({
				name     = data_class.name,
				inherits = "Object",
				brief    = is_constants ? "The game's constants (Glue.constants): [code]Unified.constants[/code]." : fmt.tprintf("The game's session data %v.", data_class.layout.type.id),
				text     = is_constants ? "The game's fixed values for its scripts, set once at load (no members when the game has none)." : fmt.tprintf("[code]Unified.data.%s[/code]: the newest tick's values (fill_frame: push_data), zero outside a session.", data_class.layout.property),
				members  = doc_members(data_class.fields),
				signals  = is_constants ? nil : []Doc_Method{{"changed", "", "", "A value changed (a new tick's, or the reset when a session ends)."}},
			}))
	}
	for enum_class in D.enums {
		constants := make([]Doc_Member, len(enum_class.info.names), context.temp_allocator)
		for name, i in enum_class.info.names {
			constants[i] = {
				strings.to_upper(name, context.temp_allocator),
				fmt.tprint(i64(enum_class.info.values[i])),
				fmt.tprintf("%v.%s", enum_class.type.id, name),
			}
		}
		gd.load_class_docs(doc_xml({
				name      = enum_class.name,
				inherits  = "Object",
				brief     = fmt.tprintf("The game's enum %v: fields of this type are ints.", enum_class.type.id),
				text      = "Compare a field with its constants; [method name] gives a member's name for display.",
				methods   = {
					{"name", "String", "value:int", "The member's name, lowercased (its value as text for none)."},
				},
				constants = constants,
			}))
	}
}

// What LIBRARY_DOCS and the library's classes disagree on (temp-allocated): a method, property, signal or constant
// bound without an entry, or an entry for one that isn't bound. load_docs reports each as an error, which fails the
// godot suite's `editor` step. UnifiedData is left out: its properties are the game's data types.
docs_problems :: proc() -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	classes := [?]^gd.Class {
		&session_class,
		&unified_view_class,
		&unified_multi_view_class,
		&D.unified,
		&event_base_class,
		&command_base_class,
	}
	for class in classes {
		doc: ^Doc_Class
		for &candidate in LIBRARY_DOCS do if candidate.name == class.name do doc = &candidate
		if doc == nil {
			append(&problems, fmt.tprintf("unified: docs.odin has no entry for %s", class.name))
			continue
		}
		documented :: proc(doc: ^Doc_Class, bound: gd.Bound) -> bool {
			#partial switch bound.kind {
			case .Method:
				for method in doc.methods do if method.name == bound.name do return true
			case .Property:
				for member in doc.members do if member.name == bound.name do return true
			case .Signal:
				for signal in doc.signals do if signal.name == bound.name do return true
			case .Constant:
				for constant in doc.constants do if constant.name == bound.name do return true
			case:
				return true // a property's accessor
			}
			return false
		}
		is_bound :: proc(class: ^gd.Class, name: string, kinds: bit_set[gd.Bound_Kind]) -> bool {
			for bound in class.bound do if bound.kind in kinds && bound.name == name do return true
			return false
		}
		for bound in class.bound {
			if !documented(doc, bound) {
				append(
					&problems,
					fmt.tprintf("unified: %s.%s (%v) has no entry in docs.odin", class.name, bound.name, bound.kind),
				)
			}
		}
		stale :: "unified: docs.odin documents %s.%s, which %s doesn't bind"
		for method in doc.methods {
			if !is_bound(class, method.name, {.Method}) {
				append(&problems, fmt.tprintf(stale, class.name, method.name, class.name))
			}
		}
		for member in doc.members {
			if !is_bound(class, member.name, {.Property}) do append(&problems, fmt.tprintf(stale, class.name, member.name, class.name))
		}
		for signal in doc.signals {
			if !is_bound(class, signal.name, {.Signal}) do append(&problems, fmt.tprintf(stale, class.name, signal.name, class.name))
		}
		for constant in doc.constants {
			if !is_bound(class, constant.name, {.Constant}) {
				append(&problems, fmt.tprintf(stale, class.name, constant.name, class.name))
			}
		}
	}
	return problems[:]
}
