package control

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// Handler is what the server does with a request. The agent implements it.
type Handler interface {
	Handle(ctx context.Context, request Request) Response
}

type Server struct {
	listener *net.UnixListener
	handler  Handler
	log      func(format string, args ...any)
	uid      int
}

// How long one exchange may take. Generous because newSession draws a token from ccmuxd,
// but bounded so a stuck client cannot hold a connection forever.
const exchangeTimeout = 60 * time.Second

// Listen binds the socket, creating its directory 0700 and refusing one that anybody
// else can reach.
func Listen(path string, handler Handler, log func(string, ...any)) (*Server, error) {
	// A sockaddr_un holds 104 bytes on macOS and 108 on Linux. Past that bind fails with
	// "invalid argument", which says nothing about the actual cause.
	if len(path) >= 104 {
		return nil, fmt.Errorf("the socket path %s is %d bytes; a unix socket allows 103",
			path, len(path))
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	if err := checkDirectory(dir); err != nil {
		return nil, err
	}
	// A socket left by a previous run refuses the bind; removing it is safe because the
	// directory is ours alone.
	if info, err := os.Stat(path); err == nil && info.Mode()&os.ModeSocket != 0 {
		_ = os.Remove(path)
	}
	address, err := net.ResolveUnixAddr("unix", path)
	if err != nil {
		return nil, err
	}
	listener, err := net.ListenUnix("unix", address)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = listener.Close()
		return nil, err
	}
	server := &Server{listener: listener, handler: handler, log: log, uid: os.Getuid()}
	return server, nil
}

// checkDirectory refuses a socket directory the group or anyone else can enter. The
// agent runs as the application's own user, so this is what keeps another user on the box
// from starting sessions that bill someone else's subscription.
func checkDirectory(dir string) error {
	info, err := os.Stat(dir)
	if err != nil {
		return err
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		return fmt.Errorf("%s is mode %04o — the control socket lives here, chmod 700 it",
			dir, perm)
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) != os.Getuid() {
		return fmt.Errorf("%s belongs to uid %d, not to this agent", dir, stat.Uid)
	}
	return nil
}

func (s *Server) Serve(ctx context.Context) {
	go func() {
		<-ctx.Done()
		_ = s.listener.Close()
	}()
	for {
		conn, err := s.listener.AcceptUnix()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			s.log("control socket: %v", err)
			return
		}
		go s.exchange(ctx, conn)
	}
}

func (s *Server) Close() error { return s.listener.Close() }

func (s *Server) exchange(ctx context.Context, conn *net.UnixConn) {
	defer conn.Close()
	if err := checkPeer(conn, s.uid); err != nil {
		s.log("control socket: refused a connection: %v", err)
		return
	}
	_ = conn.SetDeadline(time.Now().Add(exchangeTimeout))

	// Bounded: this is a local socket, but a request is still untrusted input and an
	// unbounded read is a way to exhaust a 961 MB box.
	reader := bufio.NewReaderSize(conn, 64<<10)
	line, err := reader.ReadBytes('\n')
	if err != nil && len(line) == 0 {
		return
	}
	var request Request
	response := Response{}
	if err := json.Unmarshal(line, &request); err != nil {
		response.Error = "could not read the request: " + err.Error()
	} else {
		exchangeCtx, cancel := context.WithTimeout(ctx, exchangeTimeout)
		response = s.handler.Handle(exchangeCtx, request)
		cancel()
	}
	encoded, err := json.Marshal(response)
	if err != nil {
		return
	}
	_, _ = conn.Write(append(encoded, '\n'))
}
