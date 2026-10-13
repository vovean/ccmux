package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

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
	return printStatus(os.Stdout, response.Status)
}

func printStatus(out io.Writer, raw any) error {
	// Re-decoded rather than typed: the control protocol carries this opaquely so the
	// agent package does not have to be linked into every subcommand.
	encoded, err := json.Marshal(raw)
	if err != nil {
		return err
	}
	var status struct {
		MachineLabel string `json:"machineLabel"`
		PendingUsage int    `json:"pendingUsageBuckets"`
		Group        string `json:"group"`
		GroupError   string `json:"groupError"`
		Accounts     []struct {
			Label        string   `json:"label"`
			Health       string   `json:"health"`
			Sessions     int      `json:"sessions"`
			Groups       []string `json:"groups"`
			Unusable     string   `json:"unusable"`
			NotAutomatic string   `json:"notAutomatic"`
			AgeSecs      float64  `json:"usageAgeSeconds"`
			Windows      []struct {
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

	fmt.Fprintf(out, "%s — %d session(s), %d usage bucket(s) waiting\n",
		status.MachineLabel, len(status.Sessions), status.PendingUsage)
	switch {
	case status.GroupError != "":
		fmt.Fprintf(out, "group: %s — runs without --group are refused: %s\n\n",
			status.Group, status.GroupError)
	case status.Group != "":
		fmt.Fprintf(out, "group: %s\n\n", status.Group)
	default:
		fmt.Fprint(out, "group: ungrouped accounts only\n\n")
	}
	fmt.Fprintln(out, "ACCOUNTS")
	for _, account := range status.Accounts {
		fmt.Fprintf(out, "  %-28s %-13s %d session(s)", account.Label, account.Health,
			account.Sessions)
		for _, window := range account.Windows {
			fmt.Fprintf(out, "  %s %.0f%%", window.Label, window.Percent)
		}
		fmt.Fprintf(out, "  (%.0fs old)\n", account.AgeSecs)
		if len(account.Groups) > 0 {
			label := "group"
			if len(account.Groups) > 1 {
				label = "groups"
			}
			fmt.Fprintf(out, "  %-28s %s: %s\n", "", label, strings.Join(account.Groups, ", "))
		}
		switch {
		case account.Unusable != "":
			fmt.Fprintf(out, "  %-28s not used: %s\n", "", account.Unusable)
		case account.NotAutomatic != "":
			fmt.Fprintf(out, "  %-28s not used automatically: %s\n", "",
				account.NotAutomatic)
		}
	}
	if len(status.Sessions) == 0 {
		return nil
	}
	fmt.Fprintln(out, "\nSESSIONS")
	for _, session := range status.Sessions {
		fmt.Fprintf(out, "  %s  pid %-7d port %-6d %-8s %-18s %d req  $%.4f  %s\n",
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
