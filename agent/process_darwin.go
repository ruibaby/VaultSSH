//go:build darwin

package main

/*
#cgo LDFLAGS: -lproc
#include <libproc.h>
*/
import "C"

import "unsafe"

// proc_pidpath reads the kernel's executable identity, not argv[0]. In
// particular, launching a program with argv[0]="/usr/bin/ssh" must not let it
// reuse ssh's cached authorization. It also avoids reading process arguments.
func executablePath(pid int) string {
	var path [C.PROC_PIDPATHINFO_MAXSIZE]C.char
	if C.proc_pidpath(C.int(pid), unsafe.Pointer(&path[0]), C.uint32_t(len(path))) <= 0 {
		return ""
	}
	return C.GoString(&path[0])
}
