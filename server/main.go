package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

// One housekeeping tick per interval. Short enough that a lineage is refreshed well
// before a client needs the token, long enough that the usage endpoint's hourly budget
// stays governed by PollPolicy rather than by this loop.
const tickInterval = 20 * time.Second

// How long shutdown waits for an in-flight refresh grant. Above refreshGrantTimeout, so a
// slow-but-successful rotation is not abandoned at the last moment — the whole point of
// the drain.
const refreshDrainDeadline = 40 * time.Second

var logger = log.New(os.Stdout, "", 0)

func stamp() string { return time.Now().UTC().Format("2006-01-02T15:04:05Z") }

func logInfo(format string, args ...any) {
	logger.Printf("%s INFO %s", stamp(), fmt.Sprintf(format, args...))
}
func logWarn(format string, args ...any) {
	logger.Printf("%s WARN %s", stamp(), fmt.Sprintf(format, args...))
}
func logError(format string, args ...any) {
	logger.Printf("%s ERROR %s", stamp(), fmt.Sprintf(format, args...))
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "ccmuxd: %v\n", err)
		os.Exit(2)
	}
}

func run() error {
	config, err := ParseConfig(os.Args[1:], os.Getenv)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(config.DataDir, 0o700); err != nil {
		return err
	}

	credential, err := LoadBasicAuth(config.AuthFile())
	if err != nil {
		return err
	}
	masterKey, err := LoadOrCreateMasterKey(config.MasterKeyFile())
	if err != nil {
		return err
	}
	secrets, err := NewEncryptedFileStore(config.SecretsFile(), masterKey)
	if err != nil {
		return err
	}

	registry := NewRegistry(NewOAuthClient(), secrets, config.AccountsFile())
	registry.Bootstrap()
	machines := NewMachineStore()
	hooks := NewHookStore(config.HooksFile())

	server := &http.Server{
		Addr:              net.JoinHostPort(config.Host, strconv.Itoa(config.Port)),
		Handler:           NewMux(registry, machines, hooks, credential),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	if !config.Insecure {
		certificate, err := tls.LoadX509KeyPair(config.CertPath, config.KeyPath)
		if err != nil {
			return fmt.Errorf("could not load the certificate at %s / %s: %w — run "+
				"scripts/install-ccmuxd.sh, or pass --insecure behind a TLS front end",
				config.CertPath, config.KeyPath, err)
		}
		server.TLSConfig = &tls.Config{
			Certificates: []tls.Certificate{certificate},
			MinVersion:   tls.VersionTLS12,
		}
	} else {
		logWarn("serving plain HTTP — the basic-auth credential and every access token " +
			"it returns travel in the clear")
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Housekeeping runs alongside. A tick cut off mid-refresh simply runs again next
	// start, because a rotated credential is persisted before it is considered current.
	go func() {
		ticker := time.NewTicker(tickInterval)
		defer ticker.Stop()
		registry.Tick(ctx)
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				registry.Tick(ctx)
			}
		}
	}()

	scheme := "TLS"
	if config.Insecure {
		scheme = "plain HTTP"
	}
	logInfo("ccmuxd listening on %s:%d (%s)", config.Host, config.Port, scheme)

	errs := make(chan error, 1)
	go func() {
		if config.Insecure {
			errs <- server.ListenAndServe()
		} else {
			errs <- server.ListenAndServeTLS("", "")
		}
	}()

	select {
	case err := <-errs:
		if err != nil && err != http.ErrServerClosed {
			return err
		}
	case <-ctx.Done():
		logInfo("shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
		// Shutdown waits for HTTP handlers, not for the housekeeping tick's grants. A
		// refresh abandoned by process exit is a rotation Anthropic has already made and
		// we never stored — the account is then permanently logged out, and a
		// `systemctl restart` is enough to cause it.
		if !registry.WaitForRefreshes(refreshDrainDeadline) {
			logWarn("a refresh was still in flight after %s; exiting anyway",
				refreshDrainDeadline)
		}
	}
	return nil
}
