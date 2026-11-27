package syslog

import (
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Message represents a parsed RFC 5424 or RFC 3164 syslog event.
type Message struct {
	ReceivedAt time.Time
	Timestamp  time.Time
	Priority   int
	Host       string
	AppName    string
	ProcID     string
	Body       string
	Synthetic  bool
}

// FilterLog holds parsed fields from an OPNsense filterlog CSV payload.
type FilterLog struct {
	Rule      string
	Tracker   string
	Interface string
	Action    string
	Dir       string
	IPVer     string
	Proto     string
	SrcIP     string
	DstIP     string
	SrcPort   string
	DstPort   string
}

var (
	secretPairRe   = regexp.MustCompile(`(?i)\b(token|password|passwd|secret|cookie|authorization|apikey|api_key|phpsessid|private_key)\b\s*([=:])\s*(?:"[^"]*"|'[^']*'|[^\s;,]+)`)
	secretKeyEqRe  = regexp.MustCompile(`(?i)\bkey\s*=\s*(?:"[^"]*"|'[^']*'|[^\s;,]+)`)
	bearerRe       = regexp.MustCompile(`(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+`)
	rfc3164TagRe   = regexp.MustCompile(`^([^\[:\s]+)(?:\[([^\]]+)\])?:\s*(.*)$`)
)

// ParseLine parses one RFC 5424 or RFC 3164 syslog line without retaining secrets or raw frames.
func ParseLine(raw string, now time.Time) (Message, bool) {
	line := strings.TrimSpace(strings.TrimRight(raw, "\r\n"))
	if line == "" {
		return Message{}, false
	}

	pri := -1
	rest := line
	if strings.HasPrefix(line, "<") {
		if end := strings.IndexByte(line, '>'); end > 1 && end <= 4 {
			if p, err := strconv.Atoi(line[1:end]); err == nil && p >= 0 {
				pri = p
				rest = line[end+1:]
			}
		}
	}

	if strings.HasPrefix(rest, "1 ") {
		if msg, ok := parseRFC5424(pri, rest[2:], now); ok {
			return msg, true
		}
	}
	if msg, ok := parseRFC3164(pri, rest, now); ok {
		return msg, true
	}

	// Fallback: accept unframed text only if non-empty.
	return Message{
		ReceivedAt: now,
		Timestamp:  now,
		Priority:   pri,
		Host:       "unknown",
		AppName:    "syslog",
		Body:       stripBOM(rest),
		Synthetic:  hasSyntheticMarker("", rest),
	}, true
}

func parseRFC5424(pri int, s string, now time.Time) (Message, bool) {
	tsStr, rem, ok := nextField(s)
	if !ok {
		return Message{}, false
	}
	host, rem, ok := nextField(rem)
	if !ok {
		return Message{}, false
	}
	app, rem, ok := nextField(rem)
	if !ok {
		return Message{}, false
	}
	procID, rem, ok := nextField(rem)
	if !ok {
		return Message{}, false
	}
	_, rem, ok = nextField(rem) // MSGID
	if !ok {
		return Message{}, false
	}

	sd, body, ok := parseStructuredData(rem)
	if !ok {
		return Message{}, false
	}
	body = stripBOM(strings.TrimSpace(body))

	ts := now
	if tsStr != "-" {
		if parsed, err := time.Parse(time.RFC3339Nano, tsStr); err == nil {
			ts = parsed.UTC()
		} else if parsed, err := time.Parse(time.RFC3339, tsStr); err == nil {
			ts = parsed.UTC()
		}
	}

	return Message{
		ReceivedAt: now,
		Timestamp:  ts,
		Priority:   pri,
		Host:       dashDefault(host, "unknown"),
		AppName:    dashDefault(app, "syslog"),
		ProcID:     dashDefault(procID, ""),
		Body:       body,
		Synthetic:  hasSyntheticMarker(sd, body),
	}, true
}

func parseRFC3164(pri int, s string, now time.Time) (Message, bool) {
	fields := strings.Fields(s)
	if len(fields) < 5 {
		return Message{}, false
	}
	tsCandidate := fields[0] + " " + fields[1] + " " + fields[2]
	parsedTS, err := time.Parse("Jan 2 15:04:05", tsCandidate)
	if err != nil {
		return Message{}, false
	}
	ts := time.Date(now.Year(), parsedTS.Month(), parsedTS.Day(), parsedTS.Hour(), parsedTS.Minute(), parsedTS.Second(), 0, time.UTC)

	// Locate remaining string after time field cleanly preserving multiple spaces in host/body.
	idx := 0
	for i := 0; i < 3; i++ {
		for idx < len(s) && s[idx] == ' ' {
			idx++
		}
		for idx < len(s) && s[idx] != ' ' {
			idx++
		}
	}
	rem := strings.TrimLeft(s[idx:], " ")
	host, afterHost, ok := nextField(rem)
	if !ok {
		return Message{}, false
	}
	app := "syslog"
	proc := ""
	body := afterHost
	if m := rfc3164TagRe.FindStringSubmatch(afterHost); len(m) == 4 {
		app = m[1]
		proc = m[2]
		body = m[3]
	}
	body = stripBOM(strings.TrimSpace(body))
	return Message{
		ReceivedAt: now,
		Timestamp:  ts,
		Priority:   pri,
		Host:       host,
		AppName:    app,
		ProcID:     proc,
		Body:       body,
		Synthetic:  hasSyntheticMarker("", body),
	}, true
}

func nextField(s string) (string, string, bool) {
	s = strings.TrimLeft(s, " ")
	if s == "" {
		return "", "", false
	}
	sp := strings.IndexByte(s, ' ')
	if sp == -1 {
		return s, "", true
	}
	return s[:sp], s[sp+1:], true
}

func parseStructuredData(s string) (string, string, bool) {
	s = strings.TrimLeft(s, " ")
	if s == "" {
		return "", "", false
	}
	if strings.HasPrefix(s, "- ") {
		return "-", s[2:], true
	}
	if s == "-" {
		return "-", "", true
	}
	if !strings.HasPrefix(s, "[") {
		// Tolerate missing SD field if daemon omitted it.
		return "", s, true
	}

	inBracket := false
	inQuote := false
	escaped := false
	i := 0
	for i < len(s) {
		ch := s[i]
		if escaped {
			escaped = false
			i++
			continue
		}
		if inQuote {
			if ch == '\\' {
				escaped = true
			} else if ch == '"' {
				inQuote = false
			}
			i++
			continue
		}
		if !inBracket {
			if ch == '[' {
				inBracket = true
				i++
				continue
			}
			if ch == ' ' {
				return s[:i], s[i+1:], true
			}
			break
		}
		if ch == '"' {
			inQuote = true
		} else if ch == ']' {
			inBracket = false
		}
		i++
	}
	if i == len(s) && !inBracket {
		return s, "", true
	}
	return "", s, true
}

func dashDefault(s, def string) string {
	if s == "-" || s == "" {
		return def
	}
	return s
}

func stripBOM(s string) string {
	return strings.TrimPrefix(s, "\xef\xbb\xbf")
}

func hasSyntheticMarker(sd, body string) bool {
	return strings.Contains(sd, "SYNTHETIC TEST") ||
		strings.Contains(sd, "netwatch-synthetic") ||
		strings.Contains(body, "[SYNTHETIC TEST]") ||
		strings.Contains(body, "netwatch-synthetic")
}

// ParseFilterLog decodes an OPNsense filterlog CSV line.
func ParseFilterLog(body string) (FilterLog, bool) {
	fields := strings.Split(strings.TrimSpace(body), ",")
	if len(fields) < 17 {
		return FilterLog{}, false
	}
	fl := FilterLog{
		Rule:      fields[0],
		Tracker:   fields[3],
		Interface: fields[4],
		Action:    strings.ToLower(strings.TrimSpace(fields[6])),
		Dir:       strings.ToLower(strings.TrimSpace(fields[7])),
		IPVer:     fields[8],
	}
	switch fl.IPVer {
	case "4":
		if len(fields) < 20 {
			return FilterLog{}, false
		}
		fl.Proto = strings.ToLower(strings.TrimSpace(fields[16]))
		fl.SrcIP = strings.TrimSpace(fields[18])
		fl.DstIP = strings.TrimSpace(fields[19])
		if len(fields) >= 22 {
			fl.SrcPort = strings.TrimSpace(fields[20])
			fl.DstPort = strings.TrimSpace(fields[21])
		}
	case "6":
		fl.Proto = strings.ToLower(strings.TrimSpace(fields[12]))
		fl.SrcIP = strings.TrimSpace(fields[15])
		fl.DstIP = strings.TrimSpace(fields[16])
		if len(fields) >= 19 {
			fl.SrcPort = strings.TrimSpace(fields[17])
			fl.DstPort = strings.TrimSpace(fields[18])
		}
	default:
		return FilterLog{}, false
	}
	if fl.Interface == "" || fl.Action == "" || fl.SrcIP == "" || fl.DstIP == "" {
		return FilterLog{}, false
	}
	return fl, true
}

// RedactEvidence masks credential/token values, collapses whitespace, and caps output length at 320 runes.
func RedactEvidence(raw string) string {
	s := secretPairRe.ReplaceAllString(raw, "$1$2[REDACTED]")
	s = secretKeyEqRe.ReplaceAllString(s, "key=[REDACTED]")
	s = bearerRe.ReplaceAllString(s, "Bearer [REDACTED]")
	s = strings.Join(strings.Fields(s), " ")
	runes := []rune(s)
	if len(runes) > 320 {
		return string(runes[:317]) + "..."
	}
	return s
}
