package core

import (
	"errors"
	"testing"
)

type protectionConn struct{ err error }

func (c protectionConn) Control(f func(uintptr)) error {
	if c.err != nil {
		return c.err
	}
	f(42)
	return nil
}
func (protectionConn) Read(func(uintptr) bool) error  { return nil }
func (protectionConn) Write(func(uintptr) bool) error { return nil }

func TestSocketProtectionRefusalStopsDial(t *testing.T) {
	if err := protectSocket(protectionConn{}, func(int) bool { return false }); !errors.Is(err, errNetworkProtection) {
		t.Fatalf("refused network binding must fail the dial, got %v", err)
	}
	if err := protectSocket(protectionConn{}, func(fd int) bool { return fd == 42 }); err != nil {
		t.Fatal(err)
	}
	controlError := errors.New("socket closed")
	if err := protectSocket(protectionConn{controlError}, func(int) bool {
		t.Fatal("must not protect an unavailable descriptor")
		return true
	}); !errors.Is(err, controlError) {
		t.Fatalf("lost control error: %v", err)
	}
}
