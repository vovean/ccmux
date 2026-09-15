//go:build linux

package control

import (
	"fmt"
	"net"
	"syscall"
)

// checkPeer refuses a connection from another user. The socket already sits in a
// directory only this user can enter, so this is the second of two locks rather than the
// only one — but what crosses this socket decides which subscription a run bills to.
func checkPeer(conn *net.UnixConn, allowedUID int) error {
	raw, err := conn.SyscallConn()
	if err != nil {
		return err
	}
	var creds *syscall.Ucred
	var credErr error
	if err := raw.Control(func(fd uintptr) {
		creds, credErr = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET,
			syscall.SO_PEERCRED)
	}); err != nil {
		return err
	}
	if credErr != nil {
		return credErr
	}
	if int(creds.Uid) != allowedUID {
		return fmt.Errorf("uid %d may not use this agent", creds.Uid)
	}
	return nil
}
