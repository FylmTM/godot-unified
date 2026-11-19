package cli

import "core:os"
import win32 "core:sys/windows"

// Makes a file's handle inheritable by the next process started, or not (spawn).
@(private)
set_inheritable :: proc(file: ^os.File, inheritable: bool) {
	if file == nil do return
	win32.SetHandleInformation(
		win32.HANDLE(os.fd(file)),
		win32.HANDLE_FLAG_INHERIT,
		inheritable ? win32.HANDLE_FLAG_INHERIT : 0,
	)
}
