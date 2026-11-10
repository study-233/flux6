//go:build !darwin && !linux

package paths

import (
	"errors"
	"os"
)

func AcquireWorkerLease(root *os.Root) (*os.File, error) {
	return nil, errors.New("native worker is not supported on this platform")
}
