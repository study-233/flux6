package core

import (
	"errors"
	"syscall"
)

var errNetworkProtection = errors.New("FreeV6 cannot bind the socket to Wi-Fi")

func protectSocket(conn syscall.RawConn, protect func(int) bool) error {
	protected := false
	if err := conn.Control(func(fd uintptr) { protected = protect(int(fd)) }); err != nil {
		return err
	}
	if !protected {
		return errNetworkProtection
	}
	return nil
}
