// Command forms in the Commands panel: a row per form (the host's: a game's dev commands), its fields as inputs and a
// Send button. Game-agnostic: the host describes each field (a number, a toggle, a choice) and packs what comes back.
package devui

import gd "unified:gdext"

// What one input of a form is.
Form_Field_Kind :: enum u8 {
	Number, // a SpinBox from min to max by step
	Toggle, // a CheckBox
	Choice, // an OptionButton of `choices`
}

// One input of a form.
Form_Field :: struct {
	label:          string,
	kind:           Form_Field_Kind,
	min, max, step: f64,
	choices:        []string,
}

// A form: a name (a command's) and its inputs.
Form :: struct {
	name:   string,
	fields: []Form_Field,
}

@(private)
Form_Row :: struct {
	inputs: [dynamic]gd.Control, // by field: a SpinBox, a CheckBox or an OptionButton
	kinds:  [dynamic]Form_Field_Kind,
}

@(private)
Forms :: struct {
	box:     gd.VBoxContainer, // above the Commands log
	rows:    [dynamic]Form_Row,
	sent:    int, // the form whose Send was pressed (-1: none)
	values:  [dynamic]f64,
	enabled: bool,
}

// Replaces the Commands panel's forms (call again when they change: a choice's list, the session). Empty: none.
command_forms :: proc(forms: []Form) {
	if !s.inited do return
	panel := &s.forms
	children := gd.Node_get_child_count(panel.box, false)
	for i := children - 1; i >= 0; i -= 1 {
		child := gd.Node_get_child(panel.box, i, false)
		gd.Node_remove_child(panel.box, child)
		gd.Node_queue_free(child)
	}
	for &row in panel.rows {
		delete(row.inputs)
		delete(row.kinds)
	}
	clear(&panel.rows)
	panel.sent = -1
	for form, index in forms {
		line := add(panel.box, gd.HBoxContainer_new())
		name := label(line, form.name)
		gd.Control_set_theme_type_variation(name, "DevKey")
		row: Form_Row
		for field in form.fields {
			label(line, field.label)
			switch field.kind {
			case .Number:
				spin := add(line, gd.SpinBox_new())
				gd.Range_set_min(spin, field.min)
				gd.Range_set_max(spin, field.max)
				gd.Range_set_step(spin, field.step)
				gd.Range_set_value_no_signal(spin, field.min > 0 ? field.min : 0)
				append(&row.inputs, gd.cast_to(gd.Control, spin))
			case .Toggle:
				box := add(line, gd.CheckBox_new())
				gd.Control_set_focus_mode(box, .FOCUS_NONE)
				append(&row.inputs, gd.cast_to(gd.Control, box))
			case .Choice:
				options := add(line, gd.OptionButton_new())
				gd.Control_set_focus_mode(options, .FOCUS_NONE)
				for choice in field.choices do gd.OptionButton_add_item(options, choice)
				if len(field.choices) > 0 do gd.OptionButton_select(options, 0)
				append(&row.inputs, gd.cast_to(gd.Control, options))
			}
			append(&row.kinds, field.kind)
		}
		send := button(line, "send", proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
				if s.forms.enabled do s.forms.sent = int(uintptr(user))
				return {}
			}, rawptr(uintptr(index)))
		gd.BaseButton_set_disabled(send, !panel.enabled)
		append(&panel.rows, row)
	}
	gd.CanvasItem_set_visible(panel.box, len(forms) > 0)
}

// Whether the forms can send (a session that takes commands; a replay doesn't).
command_forms_enable :: proc(enabled: bool) {
	if !s.inited do return
	s.forms.enabled = enabled
}

// The form whose Send was pressed since the last call, with its fields' values by field (a number's value, a toggle
// 0 or 1, a choice's index; temp-allocated). Nothing without the dev UI.
take_form :: proc() -> (form: int, values: []f64, ok: bool) {
	if !s.inited do return
	panel := &s.forms
	if panel.sent < 0 || panel.sent >= len(panel.rows) do return
	form, panel.sent = panel.sent, -1
	row := &panel.rows[form]
	out := make([]f64, len(row.inputs), context.temp_allocator)
	for input, i in row.inputs {
		switch row.kinds[i] {
		case .Number:
			out[i] = gd.Range_get_value(gd.cast_to(gd.Range, input))
		case .Toggle:
			out[i] = gd.BaseButton_is_pressed(gd.cast_to(gd.BaseButton, input)) ? 1 : 0
		case .Choice:
			out[i] = f64(gd.OptionButton_get_selected(gd.cast_to(gd.OptionButton, input)))
		}
	}
	return form, out, true
}

@(private)
forms_shutdown :: proc() {
	for &row in s.forms.rows {
		delete(row.inputs)
		delete(row.kinds)
	}
	delete(s.forms.rows)
	delete(s.forms.values)
}
