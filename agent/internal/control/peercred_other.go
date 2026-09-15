//go:build !linux

package control

import "net"

// Linux is the deployment target and the only platform with the peer's uid in the
// standard library. Everywhere else — macOS, where the tests run — the guard is the
// socket's directory, which Listen refuses to use unless it is owned by this user with
// nothing granted to the group or to anyone else.
func checkPeer(*net.UnixConn, int) error { return nil }
