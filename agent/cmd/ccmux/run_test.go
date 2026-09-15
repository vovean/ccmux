package main

import (
	"strings"
	"testing"

	"ccmuxagent/internal/config"
)

// The whole argument path, as an application actually invokes it: config.Load first, then
// the shim's own split. Getting the terminator wrong here runs claude with a prompt the
// caller did not write.
func argv(t *testing.T, args ...string) (string, []string) {
	t.Helper()
	_, rest, err := config.Load(args, func(string) string { return "" })
	if err != nil {
		t.Fatal(err)
	}
	launch, forwarded, err := splitRunArgs(rest)
	if err != nil {
		t.Fatal(err)
	}
	return launch.Model, withModel(launch.Model, forwarded)
}

func TestArgumentsReachClaudeExactlyAsWritten(t *testing.T) {
	for _, tc := range []struct {
		name      string
		args      []string
		wantModel string
		wantArgv  []string
	}{
		{
			name:     "the documented form",
			args:     []string{"--", "-p", "summarise this"},
			wantArgv: []string{"-p", "summarise this"},
		},
		{
			name:      "the shim's flags before the terminator",
			args:      []string{"--model", "claude-opus-5", "--", "-p", "hi"},
			wantModel: "claude-opus-5",
			// The model reaches claude too, or the account was ranked on a window the
			// request will never consume.
			wantArgv: []string{"--model", "claude-opus-5", "-p", "hi"},
		},
		{
			name: "a model the caller passes after the terminator wins",
			args: []string{"--model", "claude-opus-5", "--", "-p", "hi",
				"--model", "claude-sonnet-5"},
			wantModel: "claude-opus-5",
			wantArgv: []string{"--model", "claude-opus-5", "-p", "hi",
				"--model", "claude-sonnet-5"},
		},
		{
			name:     "no terminator at all",
			args:     []string{"-p", "hi"},
			wantArgv: []string{"-p", "hi"},
		},
		{
			// Past the terminator nothing is the shim's, however much it looks like it.
			name:     "the shim's own flags past the terminator belong to claude",
			args:     []string{"--", "-p", "hi", "--name", "not-mine"},
			wantArgv: []string{"-p", "hi", "--name", "not-mine"},
		},
		{
			name:     "an agent flag past the terminator is not consumed either",
			args:     []string{"--", "-p", "hi", "--url", "http://not-mine"},
			wantArgv: []string{"-p", "hi", "--url", "http://not-mine"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			model, got := argv(t, tc.args...)
			if model != tc.wantModel {
				t.Errorf("model = %q, want %q", model, tc.wantModel)
			}
			if strings.Join(got, "\x00") != strings.Join(tc.wantArgv, "\x00") {
				t.Errorf("argv = %q, want %q", got, tc.wantArgv)
			}
		})
	}
}
