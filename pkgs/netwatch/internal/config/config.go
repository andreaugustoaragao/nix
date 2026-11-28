package config

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"faragao.net/netwatch/internal/notify"
)

// Config holds non-secret runtime settings and secrets loaded from env / systemd credentials.
type Config struct {
	ListenAddr             string
	StateFile              string
	IngestToken            string
	FleetToken             string
	FleetManifestFile      string
	SyslogAddr             string
	SyslogStaleAfter       time.Duration
	AllowedSyslogIPs       []string
	AdminUsers             []string
	AdminSourceCIDRs       []string
	WANInterface           string
	AllowedWANInboundPorts []int
	HeartbeatURL           string
	HeartbeatInterval      time.Duration
	FeedInterval           time.Duration
	StaleAfter             time.Duration
	UrgentReminder         time.Duration
	DailyHour              int
	DigestWeekday          time.Weekday
	DigestHour             int
	SMTP                   notify.Config
}

// Load reads settings from envFile (or $CREDENTIALS_DIRECTORY/netwatch_env if present),
// allowing process environment variables to override file entries.
func Load(envFile string) (Config, error) {
	fileVars := make(map[string]string)
	path := strings.TrimSpace(envFile)
	if path == "" {
		if credDir := strings.TrimSpace(os.Getenv("CREDENTIALS_DIRECTORY")); credDir != "" {
			candidate := filepath.Join(credDir, "netwatch_env")
			if _, err := os.Stat(candidate); err == nil {
				path = candidate
			}
		}
	}
	if path == "" {
		const sopsPath = "/run/secrets/netwatch_env"
		if f, err := os.Open(sopsPath); err == nil {
			_ = f.Close()
			path = sopsPath
		}
	}
	if path != "" {
		parsed, err := ParseEnvFile(path)
		if err != nil {
			return Config{}, err
		}
		fileVars = parsed
	}

	get := func(key, def string) string {
		if v, ok := os.LookupEnv(key); ok && strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
		if v, ok := fileVars[key]; ok && strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
		return def
	}

	hbInt, err := time.ParseDuration(get("NETWATCH_HEARTBEAT_INTERVAL", "5m"))
	if err != nil || hbInt <= 0 {
		return Config{}, fmt.Errorf("invalid NETWATCH_HEARTBEAT_INTERVAL: %v", err)
	}
	feedInt, err := time.ParseDuration(get("NETWATCH_FEED_INTERVAL", "6h"))
	if err != nil || feedInt <= 0 {
		return Config{}, fmt.Errorf("invalid NETWATCH_FEED_INTERVAL: %v", err)
	}
	staleAfter, err := time.ParseDuration(get("NETWATCH_STALE_AFTER", "50h"))
	if err != nil || staleAfter <= 0 {
		return Config{}, fmt.Errorf("invalid NETWATCH_STALE_AFTER: %v", err)
	}
	urgentRem, err := time.ParseDuration(get("NETWATCH_URGENT_REMINDER", "24h"))
	if err != nil || urgentRem <= 0 {
		return Config{}, fmt.Errorf("invalid NETWATCH_URGENT_REMINDER: %v", err)
	}
	syslogStale, err := time.ParseDuration(get("NETWATCH_SYSLOG_STALE_AFTER", "15m"))
	if err != nil || syslogStale <= 0 {
		return Config{}, fmt.Errorf("invalid NETWATCH_SYSLOG_STALE_AFTER: %v", err)
	}
	allowedWANPorts, err := parsePortList(get("NETWATCH_ALLOWED_WAN_PORTS", "443"))
	if err != nil {
		return Config{}, fmt.Errorf("invalid NETWATCH_ALLOWED_WAN_PORTS: %w", err)
	}

	dailyHour, err := strconv.Atoi(get("NETWATCH_DAILY_HOUR", "8"))
	if err != nil || dailyHour < 0 || dailyHour > 23 {
		return Config{}, fmt.Errorf("invalid NETWATCH_DAILY_HOUR")
	}
	digestHour, err := strconv.Atoi(get("NETWATCH_DIGEST_HOUR", "9"))
	if err != nil || digestHour < 0 || digestHour > 23 {
		return Config{}, fmt.Errorf("invalid NETWATCH_DIGEST_HOUR")
	}
	weekday, err := parseWeekday(get("NETWATCH_DIGEST_WEEKDAY", "Sunday"))
	if err != nil {
		return Config{}, err
	}
	smtpPort, err := strconv.Atoi(get("NETWATCH_SMTP_PORT", "465"))
	if err != nil || smtpPort <= 0 || smtpPort > 65535 {
		return Config{}, fmt.Errorf("invalid NETWATCH_SMTP_PORT")
	}

	recipients := splitCSV(get("NETWATCH_MAIL_TO", ""))

	return Config{
		ListenAddr:             get("NETWATCH_LISTEN_ADDR", "0.0.0.0:9400"),
		StateFile:              get("NETWATCH_STATE_FILE", "/var/lib/netwatch/state.json"),
		IngestToken:            get("NETWATCH_INGEST_TOKEN", ""),
		FleetToken:             get("NETWATCH_FLEET_TOKEN", ""),
		FleetManifestFile:      get("NETWATCH_FLEET_FILE", "/etc/netwatch/fleet-posture.json"),
		SyslogAddr:             get("NETWATCH_SYSLOG_ADDR", ""),
		SyslogStaleAfter:       syslogStale,
		AllowedSyslogIPs:       splitCSV(get("NETWATCH_SYSLOG_ALLOWED_IPS", "192.168.100.2,127.0.0.1,::1")),
		AdminUsers:             splitCSV(get("NETWATCH_ADMIN_USERS", "andre")),
		AdminSourceCIDRs:       splitCSV(get("NETWATCH_ADMIN_SOURCES", "192.168.10.75/32,192.168.50.0/24")),
		WANInterface:           get("NETWATCH_WAN_IFACE", "igc1"),
		AllowedWANInboundPorts: allowedWANPorts,
		HeartbeatURL:           get("NETWATCH_HEARTBEAT_URL", ""),
		HeartbeatInterval:      hbInt,
		FeedInterval:           feedInt,
		StaleAfter:             staleAfter,
		UrgentReminder:         urgentRem,
		DailyHour:              dailyHour,
		DigestWeekday:          weekday,
		DigestHour:             digestHour,
		SMTP: notify.Config{
			Host:     get("NETWATCH_SMTP_HOST", "smtp.mx.cloudflare.net"),
			Port:     smtpPort,
			TLSMode:  get("NETWATCH_SMTP_TLS", "implicit"),
			Username: get("NETWATCH_SMTP_USER", "api_token"),
			Password: get("NETWATCH_SMTP_PASS", ""),
			From:     get("NETWATCH_MAIL_FROM", "faragao.net netwatch <ops@alerts.faragao.net>"),
			To:       recipients,
		},
	}, nil
}

func splitCSV(raw string) []string {
	var out []string
	for _, part := range strings.Split(raw, ",") {
		p := strings.TrimSpace(part)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func parsePortList(raw string) ([]int, error) {
	parts := splitCSV(raw)
	out := make([]int, 0, len(parts))
	for _, part := range parts {
		p, err := strconv.Atoi(part)
		if err != nil || p <= 0 || p > 65535 {
			return nil, fmt.Errorf("invalid port %q", part)
		}
		out = append(out, p)
	}
	return out, nil
}

// ParseEnvFile parses KEY=VALUE environment files without executing shell code.
func ParseEnvFile(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open env file %s: %w", path, err)
	}
	defer f.Close()

	out := make(map[string]string)
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key := strings.TrimSpace(k)
		val := strings.TrimSpace(v)
		if len(val) >= 2 && ((val[0] == '"' && val[len(val)-1] == '"') || (val[0] == '\'' && val[len(val)-1] == '\'')) {
			val = val[1 : len(val)-1]
		}
		if key != "" {
			out[key] = val
		}
	}
	return out, sc.Err()
}

func parseWeekday(raw string) (time.Weekday, error) {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "sun", "sunday":
		return time.Sunday, nil
	case "mon", "monday":
		return time.Monday, nil
	case "tue", "tuesday":
		return time.Tuesday, nil
	case "wed", "wednesday":
		return time.Wednesday, nil
	case "thu", "thursday":
		return time.Thursday, nil
	case "fri", "friday":
		return time.Friday, nil
	case "sat", "saturday":
		return time.Saturday, nil
	default:
		return time.Sunday, fmt.Errorf("invalid weekday %q", raw)
	}
}
