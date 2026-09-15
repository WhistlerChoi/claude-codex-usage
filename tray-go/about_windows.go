//go:build windows

package main

import (
	"syscall"
	"unsafe"
)

var (
	user32      = syscall.NewLazyDLL("user32.dll")
	messageBoxW = user32.NewProc("MessageBoxW")
)

func showAbout() {
	title, _ := syscall.UTF16PtrFromString("About Pulse")
	message, _ := syscall.UTF16PtrFromString(aboutMessage())
	// MB_OK | MB_ICONINFORMATION
	_, _, _ = messageBoxW.Call(0, uintptr(unsafe.Pointer(message)), uintptr(unsafe.Pointer(title)), 0x40)
}
