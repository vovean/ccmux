package main

import (
	"encoding/json"
	"fmt"
	"os"

	"ccmuxagent/internal/config"
	"ccmuxagent/internal/control"
)

func runStatus(args []string) error {
	cfg, rest, err := config.Load(args, os.Getenv)
	if err != nil {
		return err
	}
	asJSON := false
	for _, arg := range rest {
		if arg == "--json" {
			asJSON = true
			continue
		}
		return fmt.Errorf("unexpected argument %q", arg)
	}
	response, err := control.Send(cfg.Agent.Socket, control.Request{Op: control.OpStatus})
	if err != nil {
		return err
	}
	if !response.OK {
		return fmt.Errorf("%s", response.Error)
	}
	if asJSON {
		encoded, err := json.MarshalIndent(response.Status, "", "  ")
		if err != nil {
			return err
		}
		fmt.Println(string(encoded))
		return nil
	}
	return printStatus(response.Status)
}

func printStatus(raw any) error {
	// Re-decoded rather than typed: the control protocol carries this opaquely so the
	// agent package does not have to be linked into every subcommand.
	encoded, err := json.Marshal(raw)
	if err != nil {
		return err
	}
	var status struct {
		MachineLabel string `json:"machineLabel"`
		PendingUsage int    `json:"pendingUsageBuckets"`
		Accounts     []struct {
			Label    string  `json:"label"`
			Health   string  `json:"health"`
			Sessions int     `json:"sessions"`
			Unusable string  `json:"unusable"`
			AgeSecs  float64 `json:"usageAgeSeconds"`
			Windows  []struct {
				Label   string  `json:"label"`
				Percent float64 `json:"percent"`
			} `json:"windows"`
		} `json:"accounts"`
		Sessions []struct {
			ID       string  `json:"id"`
			PID      int     `json:"pid"`
			Port     int     `json:"port"`
			Model    string  `json:"model"`
			Name     string  `json:"name"`
			Status   string  `json:"status"`
			Requests int     `json:"requests"`
			SpendUSD float64 `json:"spendUSD"`
		} `json:"sessions"`
	}
	if err := json.Unmarshal(encoded, &status); err != nil {
		return err
	}

	fmt.Printf("%s — %d session(s), %d usage bucket(s) waiting\n\n",
		status.MachineLabel, len(status.Sessions), status.PendingUsage)
	fmt.Println("ACCOUNTS")
	for _, account := range status.Accounts {
		fmt.Printf("  %-28s %-13s %d session(s)", account.Label, account.Health,
			account.Sessions)
		for _, window := range account.Windows {
			fmt.Printf("  %s %.0f%%", window.Label, window.Percent)
		}
		fmt.Printf("  (%.0fs old)\n", account.AgeSecs)
		if account.Unusable != "" {
			fmt.Printf("  %-28s not used: %s\n", "", account.Unusable)
		}
	}
	if len(status.Sessions) == 0 {
		return nil
	}
	fmt.Println("\nSESSIONS")
	for _, session := range status.Sessions {
		fmt.Printf("  %s  pid %-7d port %-6d %-8s %-18s %d req  $%.4f  %s\n",
			session.ID[:8], session.PID, session.Port, session.Status,
			session.Model, session.Requests, session.SpendUSD, session.Name)
	}
	return nil
}

func runAssign(args []string) error {
	cfg, rest, err := config.Load(args, os.Getenv)
	if err != nil {
		return err
	}
	if len(rest) != 2 {
		return fmt.Errorf("usage: ccmux assign <session> <account>")
	}
	response, err := control.Send(cfg.Agent.Socket, control.Request{
		Op: control.OpAssign, SessionID: rest[0], AccountID: rest[1]})
	if err != nil {
		return err
	}
	if !response.OK {
		return fmt.Errorf("%s", response.Error)
	}
	return nil
}

func runEnd(args []string) error {
	cfg, rest, err := config.Load(args, os.Getenv)
	if err != nil {
		return err
	}
	if len(rest) != 1 {
		return fmt.Errorf("usage: ccmux end <session>")
	}
	response, err := control.Send(cfg.Agent.Socket, control.Request{
		Op: control.OpEndSession, SessionID: rest[0]})
	if err != nil {
		return err
	}
	if !response.OK {
		return fmt.Errorf("%s", response.Error)
	}
	return nil
}
