//go:build !windows

package main

import "fmt"

// The macOS menu-bar build is the primary macOS UI. Keep the tray target
// buildable on other hosts and provide a useful fallback for development runs.
func showAbout() {
	fmt.Println(aboutMessage())
}
