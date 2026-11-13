//go:build windows

package main

import (
	"context"
	"errors"
	"net"
	"os"
	"syscall"
	"testing"

	"golang.org/x/sys/windows"
)

func TestControllerFallbackWhenWindowsDeniesExclusiveBind(t *testing.T) {
	// WinSock defines SO_EXCLUSIVEADDRUSE as ~SO_REUSEADDR. Both errors
	// below occur on a denied bind, depending on the socket and Windows build.
	config := net.ListenConfig{Control: func(_, _ string, raw syscall.RawConn) error {
		var setErr error
		if err := raw.Control(func(fd uintptr) {
			setErr = windows.SetsockoptInt(windows.Handle(fd), windows.SOL_SOCKET, ^windows.SO_REUSEADDR, 1)
		}); err != nil {
			return err
		}
		return setErr
	}}
	exclusive, err := config.Listen(context.Background(), "tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer exclusive.Close()
	preferred := exclusive.Addr().(*net.TCPAddr).AddrPort()
	legacy, err := reserveController(preferred, false)
	if legacy != nil {
		legacy.Close()
		t.Fatal("legacy bound exclusive socket")
	}
	if !errors.Is(err, windows.WSAEACCES) && !errors.Is(err, windows.WSAEADDRINUSE) {
		t.Fatalf("expected a bind conflict: %v", err)
	}
	reserved, err := reserveController(preferred, true)
	if err != nil {
		t.Fatal(err)
	}
	defer reserved.Close()
	if reserved.Addr().String() == exclusive.Addr().String() {
		t.Fatal("did not switch ports")
	}
}

// A live process must never be judged orphaned — this is the branch that used
// to mis-fire (powershell blocked → "unknown" → no takeover; recycled parent
// PID → "live" → no takeover). Both now resolve through Win32, so a plain
// self-check is enough to catch a regression in the plumbing.
func TestIsOrphanedFalseForLiveProcess(t *testing.T) {
	if isOrphaned(os.Getpid()) {
		t.Fatal("a running process must not be reported as orphaned")
	}
}

func TestProcessImagePathResolvesSelf(t *testing.T) {
	path, err := processImagePath(uint32(os.Getpid()))
	if err != nil {
		t.Fatalf("processImagePath(self): %v", err)
	}
	if path == "" {
		t.Fatal("processImagePath(self) returned an empty path")
	}
}
