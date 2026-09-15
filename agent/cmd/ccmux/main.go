// Command ccmux runs Claude Code on a pool of subscriptions.
//
// `ccmux agent` is the daemon systemd runs; `ccmux run` is the shim an application
// launches instead of claude.
package main

import (
	"fmt"
	"os"

	"ccmuxagent/internal/config"
)

// Version is stamped at build time: -ldflags "-X main.Version=1.0".
var Version = "dev"

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, config.Usage)
		os.Exit(2)
	}
	args := os.Args[2:]
	var err error
	switch os.Args[1] {
	case "agent":
		err = runAgent(args)
	case "run":
		err = runShim(args)
	case "status":
		err = runStatus(args)
	case "assign":
		err = runAssign(args)
	case "end":
		err = runEnd(args)
	case "version", "--version":
		fmt.Println("ccmux", Version)
		return
	case "help", "--help", "-h":
		fmt.Print(config.Usage)
		return
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n%s", os.Args[1], config.Usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "ccmux: "+err.Error())
		os.Exit(exitCode(err))
	}
}
