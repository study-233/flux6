//go:build !darwin && !linux

package worker

import (
	"errors"
	"os"
)

const importFileFlags = 0

func StandardPipes() (*os.File, *os.File, error) {
	return nil, nil, errors.New("native worker is not supported on this platform")
}
