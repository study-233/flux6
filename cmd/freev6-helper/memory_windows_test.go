//go:build windows

package main

import (
	"os"
	"testing"
)

func TestProcessWorkingSet(t *testing.T) {
	if processWorkingSet(os.Getpid()) == 0 {
		t.Fatal("could not read own working set")
	}
	if processWorkingSet(0) != 0 {
		t.Fatal("invalid PID has memory")
	}
}
