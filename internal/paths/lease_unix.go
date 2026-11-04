//go:build darwin || linux

package paths

import (
	"errors"
	"os"
	"syscall"
)

// A worker holds this lease until exit, preventing competing App instances
// from racing a settings revision. The persistent lock file is never unlinked.
func AcquireWorkerLease(root *os.Root) (*os.File, error) {
	f, err := root.OpenFile("worker.lock", os.O_RDWR|os.O_CREATE|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0o600)
	if err != nil {
		return nil, err
	}
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		f.Close()
		return nil, errors.New("invalid worker lock")
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, errors.New("another worker is using this data directory")
	}
	return f, nil
}
