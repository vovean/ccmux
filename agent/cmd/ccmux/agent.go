package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"ccmuxagent/internal/agent"
	"ccmuxagent/internal/client"
	"ccmuxagent/internal/config"
	"ccmuxagent/internal/control"
)

func runAgent(args []string) error {
	cfg, rest, err := config.Load(args, os.Getenv)
	if err != nil {
		return err
	}
	// The daemon has no child to forward to, so an argument it does not recognise is a
	// mistake rather than something to pass on.
	if len(rest) > 0 {
		return fmt.Errorf("unexpected argument %q", rest[0])
	}
	if err := cfg.Validate(); err != nil {
		return err
	}
	password, err := cfg.Password(os.Getenv)
	if err != nil {
		return err
	}
	api, err := client.New(cfg, password)
	if err != nil {
		return err
	}

	logger := log.New(os.Stdout, "", log.LstdFlags|log.LUTC)
	say := func(format string, args ...any) { logger.Printf(format, args...) }

	daemon, err := agent.New(cfg, api, say)
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if err := daemon.Start(ctx); err != nil {
		return err
	}
	socket, err := control.Listen(cfg.Agent.Socket, daemon, say)
	if err != nil {
		return err
	}
	defer socket.Close()
	go socket.Serve(ctx)

	say("ccmux agent %s — machine %s (%s), socket %s", Version,
		daemon.Machine().Label, daemon.Machine().ID[:8], cfg.Agent.Socket)
	daemon.Run(ctx)
	say("ccmux agent stopped")
	return nil
}
