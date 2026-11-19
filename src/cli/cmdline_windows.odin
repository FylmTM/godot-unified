package cli

import win32 "core:sys/windows"

// The process's command line as Windows passed it, before the C runtime split it into arguments (which drops every
// double quote not written \"): `drive eval` reads an expression's quotes from it (eval_expression).
@(private)
raw_command_line :: proc() -> string {
	text, _ := win32.wstring_to_utf8(win32.wstring(win32.GetCommandLineW()), -1)
	return text
}
