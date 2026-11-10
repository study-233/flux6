//go:build darwin || linux

package worker

import (
	"errors"
	"os"
	"syscall"
)

const importFileFlags = syscall.O_NONBLOCK | syscall.O_NOFOLLOW

// Inherited os.Stdin/Stdout can be blocking, non-pollable files. Closing such
// a File does not interrupt a concurrent read/write on Darwin. Duplicate and
// register nonblocking pipe descriptors with Go's runtime poller so SIGTERM
// and output backpressure cannot prevent Serve from canceling its IO.
func StandardPipes() (*os.File, *os.File, error) {
	input, err := pollablePipe(os.Stdin)
	if err != nil {
		return nil, nil, err
	}
	output, err := pollablePipe(os.Stdout)
	if err != nil {
		input.Close()
		return nil, nil, err
	}
	os.Stdin.Close()
	os.Stdout.Close()
	return input, output, nil
}

func pollablePipe(original *os.File) (*os.File, error) {
	info, err := original.Stat()
	if err != nil {
		return nil, err
	}
	if info.Mode()&os.ModeNamedPipe == 0 {
		return nil, errors.New("worker requires private pipes")
	}
	fd, err := syscall.Dup(int(original.Fd()))
	if err != nil {
		return nil, err
	}
	syscall.CloseOnExec(fd)
	if err := syscall.SetNonblock(fd, true); err != nil {
		syscall.Close(fd)
		return nil, err
	}
	return os.NewFile(uintptr(fd), original.Name()), nil
}
