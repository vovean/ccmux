package control

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type echoHandler struct{ seen Request }

func (h *echoHandler) Handle(_ context.Context, request Request) Response {
	h.seen = request
	if request.Op == "boom" {
		return Response{Error: "no"}
	}
	return Response{OK: true, Session: &SessionInfo{
		SessionID: "s1", NamespaceDir: "/ns/s1", Port: 18000, AccountLabel: "Work"}}
}

// A unix socket path is bounded at ~104 bytes, and the default temp directory name is
// long enough on its own to overflow it.
func shortTempDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "ccmux")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

func listen(t *testing.T, handler Handler) string {
	t.Helper()
	socket := filepath.Join(shortTempDir(t), "run", "c.sock")
	server, err := Listen(socket, handler, func(string, ...any) {})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	go server.Serve(ctx)
	t.Cleanup(func() { cancel(); _ = server.Close() })
	return socket
}

func TestARequestRoundTrips(t *testing.T) {
	handler := &echoHandler{}
	socket := listen(t, handler)

	response, err := Send(socket, Request{Op: OpNewSession, Model: "claude-opus-5", PID: 42})
	if err != nil {
		t.Fatal(err)
	}
	if !response.OK || response.Session == nil || response.Session.Port != 18000 {
		t.Fatalf("got %+v", response)
	}
	if handler.seen.Model != "claude-opus-5" || handler.seen.PID != 42 {
		t.Fatalf("the agent saw %+v", handler.seen)
	}
}

func TestAnErrorComesBackAsOne(t *testing.T) {
	socket := listen(t, &echoHandler{})
	response, err := Send(socket, Request{Op: "boom"})
	if err != nil {
		t.Fatal(err)
	}
	if response.OK || response.Error != "no" {
		t.Fatalf("got %+v", response)
	}
}

// One exchange per connection, so several runs starting at once do not queue behind each
// other.
func TestConnectionsAreIndependent(t *testing.T) {
	socket := listen(t, &echoHandler{})
	for i := 0; i < 5; i++ {
		if _, err := Send(socket, Request{Op: OpPing}); err != nil {
			t.Fatalf("exchange %d: %v", i, err)
		}
	}
}

func TestGarbageIsRefusedRatherThanCrashing(t *testing.T) {
	socket := listen(t, &echoHandler{})
	conn, err := dial(socket)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte("this is not json\n")); err != nil {
		t.Fatal(err)
	}
	buffer := make([]byte, 512)
	n, err := conn.Read(buffer)
	if err != nil {
		t.Fatalf("no answer: %v", err)
	}
	if n == 0 {
		t.Fatal("empty answer")
	}
}

// What crosses this socket decides which subscription a run bills to, so a directory
// anyone else can enter is refused rather than used.
func TestADirectoryOthersCanEnterIsRefused(t *testing.T) {
	dir := filepath.Join(shortTempDir(t), "run")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	_, err := Listen(filepath.Join(dir, "c.sock"), &echoHandler{},
		func(string, ...any) {})
	if err == nil {
		t.Fatal("a world-readable socket directory was accepted")
	}
}

// A socket left behind by a killed agent must not stop the next one starting.
func TestAStaleSocketIsReplaced(t *testing.T) {
	handler := &echoHandler{}
	dir := filepath.Join(shortTempDir(t), "run")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(dir, "c.sock")
	first, err := Listen(socket, handler, func(string, ...any) {})
	if err != nil {
		t.Fatal(err)
	}
	// Closing the listener without removing the file is what a kill -9 leaves.
	_ = first.Close()
	second, err := Listen(socket, handler, func(string, ...any) {})
	if err != nil {
		t.Fatalf("a stale socket blocked the restart: %v", err)
	}
	defer second.Close()
}

func TestAnOverlongSocketPathSaysSo(t *testing.T) {
	long := filepath.Join(shortTempDir(t), strings.Repeat("d", 120), "c.sock")
	_, err := Listen(long, &echoHandler{}, func(string, ...any) {})
	if err == nil || !strings.Contains(err.Error(), "unix socket allows") {
		t.Fatalf("got %v", err)
	}
}
