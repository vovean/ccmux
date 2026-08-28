package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type Config struct {
	DataDir  string
	CertPath string
	KeyPath  string
	Host     string
	Port     int
	// Off only for tests and for a run behind something else terminating TLS. Basic auth
	// over cleartext hands over the credential and every access token with it, so the
	// flag is deliberately awkward to reach for.
	Insecure bool
}

func (c Config) AccountsFile() string  { return filepath.Join(c.DataDir, "accounts.json") }
func (c Config) SecretsFile() string   { return filepath.Join(c.DataDir, "secrets.sealed") }
func (c Config) MasterKeyFile() string { return filepath.Join(c.DataDir, "master.key") }
func (c Config) AuthFile() string      { return filepath.Join(c.DataDir, "auth") }

const usage = `ccmuxd — holds ccmux's accounts and their refresh lineages.

  --data-dir PATH   accounts, sealed secrets and the auth file (default /var/lib/ccmuxd)
  --cert PATH       TLS certificate chain, PEM (default /etc/ccmuxd/cert.pem)
  --key PATH        TLS private key, PEM (default /etc/ccmuxd/key.pem)
  --host ADDR       bind address (default 0.0.0.0)
  --port N          bind port (default 8443)
  --insecure        serve plain HTTP — tests and TLS-terminating front ends only

The auth file is ` + "`username:sha256-hex-of-password`" + `, one line, mode 0600.
scripts/install-ccmuxd.sh writes one and prints the password once.`

func ParseConfig(args []string, env func(string) string) (Config, error) {
	config := Config{
		DataDir:  "/var/lib/ccmuxd",
		CertPath: "/etc/ccmuxd/cert.pem",
		KeyPath:  "/etc/ccmuxd/key.pem",
		Host:     "0.0.0.0",
		Port:     8443,
	}
	if raw := env("CCMUXD_DATA_DIR"); raw != "" {
		config.DataDir = raw
	}

	for i := 0; i < len(args); i++ {
		flag := args[i]
		value := func() (string, error) {
			i++
			if i >= len(args) {
				return "", fmt.Errorf("%s needs a value", flag)
			}
			return args[i], nil
		}
		var err error
		var raw string
		switch flag {
		case "--data-dir":
			if raw, err = value(); err == nil {
				config.DataDir = raw
			}
		case "--cert":
			if raw, err = value(); err == nil {
				config.CertPath = raw
			}
		case "--key":
			if raw, err = value(); err == nil {
				config.KeyPath = raw
			}
		case "--host":
			if raw, err = value(); err == nil {
				config.Host = raw
			}
		case "--port":
			if raw, err = value(); err == nil {
				parsed, convErr := strconv.Atoi(raw)
				if convErr != nil || parsed < 1 || parsed > 65535 {
					err = fmt.Errorf("--port must be 1-65535, got %s", raw)
				} else {
					config.Port = parsed
				}
			}
		case "--insecure":
			config.Insecure = true
		case "-h", "--help":
			return Config{}, fmt.Errorf("%s", usage)
		default:
			return Config{}, fmt.Errorf("unknown flag %s\n\n%s", flag, usage)
		}
		if err != nil {
			return Config{}, err
		}
	}
	return config, nil
}

func LoadBasicAuth(path string) (BasicAuthCredential, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return BasicAuthCredential{}, fmt.Errorf(
			"no auth file at %s — run scripts/install-ccmuxd.sh", path)
	}
	line := strings.TrimSpace(string(raw))
	parts := strings.SplitN(line, ":", 2)
	if len(parts) != 2 || parts[0] == "" || len(parts[1]) != 64 {
		return BasicAuthCredential{}, fmt.Errorf(
			"auth file must be `username:sha256-hex-of-password`")
	}
	return BasicAuthCredential{
		Username:     parts[0],
		PasswordHash: strings.ToLower(parts[1]),
	}, nil
}
