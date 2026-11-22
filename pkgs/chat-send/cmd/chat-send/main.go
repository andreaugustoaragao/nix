package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"chat-send/internal/chatsend"
)

func defaultPath(envVar, fallbackRel, suffix string) string {
	base := os.Getenv(envVar)
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, fallbackRel)
	}
	return filepath.Join(base, suffix)
}

func parseArgs(argv []string) (chatsend.Options, error) {
	opts := chatsend.Options{
		RoutesFile: defaultPath("XDG_CONFIG_HOME", ".config", "chat-send/routes.json"),
		StateDir:   defaultPath("XDG_STATE_HOME", ".local/state", "chat-send"),
		FastTests:  os.Getenv("CHAT_SEND_FAST_TESTS") == "1",
	}
	for i := 0; i < len(argv); i++ {
		arg := argv[i]
		if !strings.HasPrefix(arg, "-") {
			if opts.Mode != "" || (arg != "status" && arg != "cancel") {
				return opts, fmt.Errorf("unexpected argument: %s", arg)
			}
			opts.Mode = arg
			continue
		}
		nextVal := func() (string, error) {
			if i+1 >= len(argv) {
				return "", fmt.Errorf("missing value for %s", arg)
			}
			i++
			return argv[i], nil
		}
		key := arg
		var val string
		hasEq := false
		if idx := strings.IndexByte(arg, '='); idx >= 0 {
			key = arg[:idx]
			val = arg[idx+1:]
			hasEq = true
		}
		switch key {
		case "--send":
			if hasEq {
				return opts, fmt.Errorf("--send does not take a value")
			}
			opts.Send = true
		case "--route":
			if !hasEq {
				var err error
				val, err = nextVal()
				if err != nil {
					return opts, err
				}
			}
			opts.Route = val
		case "--message":
			if !hasEq {
				var err error
				val, err = nextVal()
				if err != nil {
					return opts, err
				}
			}
			opts.Message = val
		case "--operation":
			if !hasEq {
				var err error
				val, err = nextVal()
				if err != nil {
					return opts, err
				}
			}
			opts.Operation = val
		case "--attach":
			if !hasEq {
				var err error
				val, err = nextVal()
				if err != nil {
					return opts, err
				}
			}
			opts.Attach = append(opts.Attach, val)
		case "--routes-file":
			if !hasEq {
				var err error
				val, err = nextVal()
				if err != nil {
					return opts, err
				}
			}
			opts.RoutesFile = val
		case "--state-dir":
			if !hasEq {
				var err error
				val, err = nextVal()
				if err != nil {
					return opts, err
				}
			}
			opts.StateDir = val
		case "-h", "--help":
			fmt.Fprintln(os.Stderr, "Usage: chat-send [status|cancel] [--route ALIAS] [--message FILE] [--attach FILE ...] [--send] [--operation ID] [--routes-file FILE] [--state-dir DIR]")
			os.Exit(0)
		default:
			return opts, fmt.Errorf("unknown flag: %s", key)
		}
	}
	return opts, nil
}

func main() {
	opts, err := parseArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	result := chatsend.Run(opts)
	raw, _ := chatsend.Encode(result)
	fmt.Println(string(raw))
	outcome, _ := result["outcome"].(string)
	os.Exit(chatsend.ExitCode(outcome))
}
