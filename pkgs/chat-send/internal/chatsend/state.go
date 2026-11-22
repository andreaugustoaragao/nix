package chatsend

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
)

const (
	Signature             = "- sent by Fulcrum"
	Marker                = "\u200b"
	MaxAttachment         = 26_214_400
	MaxJSONBytes          = 131_072
	MaxReceiptBytes       = 512 * 1024
	MaxBrowserOutputBytes = 4 * 1024 * 1024
	MaxScreenshotSize     = 16 * 1024 * 1024
)

var (
	TokenRe        = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$`)
	ChatURLRe      = regexp.MustCompile(`^https://chat\.google\.com/(?:u/[0-9]+/)?app/(?:chat|space)/[a-zA-Z0-9_-]+$`)
	ChatURLStripRe = regexp.MustCompile(`^https://chat\.google\.com/(?:u/[0-9]+/)?`)
	EmailRe        = regexp.MustCompile(`^[^\s()@]+@[^\s()@]+$`)
	LangRe         = regexp.MustCompile(`^[a-zA-Z0-9_+.-]{0,24}$`)
	QueryRe        = regexp.MustCompile(`^[a-zA-Z0-9]{2,24}$`)
	WhitespaceRe   = regexp.MustCompile(`\s+`)
	MultiNewlineRe = regexp.MustCompile(`\n{3,}`)
)

var EditorTarget = map[string]any{
	"role":  "textbox",
	"name":  "History is on",
	"exact": true,
}

// StopError carries a bounded outcome and machine-readable reason.
type StopError struct {
	Reason  string
	Outcome string
}

func (e *StopError) Error() string { return e.Reason }

func Stop(reason string, outcomes ...string) *StopError {
	outcome := "needs_attention"
	if len(outcomes) > 0 && outcomes[0] != "" {
		outcome = outcomes[0]
	}
	return &StopError{Reason: reason, Outcome: outcome}
}

func ExitCode(outcome string) int {
	switch outcome {
	case "preview", "sent":
		return 0
	case "needs_attention":
		return 2
	case "uncertain":
		return 3
	default:
		return 1
	}
}

func NewUUIDHex() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return hex.EncodeToString(b[:]), nil
}

// Encode produces compact canonical JSON with sorted map keys and unescaped HTML/UTF-8.
func Encode(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

// Digest returns the lowercase SHA-256 hex digest of Encode(v).
func Digest(v any) (string, error) {
	raw, err := Encode(v)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]), nil
}

func RouteKey(rawURL string) (string, error) {
	stripped := ChatURLStripRe.ReplaceAllString(rawURL, "")
	return Digest(stripped)
}

func NormalizeSpace(s string) string {
	return strings.TrimSpace(WhitespaceRe.ReplaceAllString(s, " "))
}

func PrivateDir(path string) (string, error) {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return "", Stop("unsafe_state_directory", "failed")
	}
	info, err := os.Lstat(path)
	if err != nil {
		return "", Stop("unsafe_state_directory", "failed")
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.IsDir() || int(st.Uid) != os.Getuid() {
		return "", Stop("unsafe_state_directory", "failed")
	}
	if err := os.Chmod(path, 0o700); err != nil {
		return "", Stop("unsafe_state_directory", "failed")
	}
	return path, nil
}

func syncDir(dir string) error {
	f, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}

func AtomicWriteJSON(path string, v any) error {
	data, err := Encode(v)
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".write-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.Remove(tmpName)
		}
	}()
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	cleanup = false
	return syncDir(dir)
}

func ReadJSON(path string, private bool) (map[string]any, error) {
	return ReadJSONBounded(path, private, MaxJSONBytes)
}

func ReadReceiptJSON(path string) (map[string]any, error) {
	return ReadJSONBounded(path, true, MaxReceiptBytes)
}

func ReadJSONBounded(path string, private bool, maxBytes int64) (map[string]any, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, Stop("unreadable_or_invalid_json")
	}
	if !info.Mode().IsRegular() || info.Size() > maxBytes {
		return nil, Stop("invalid_input_file")
	}
	if private {
		st, ok := info.Sys().(*syscall.Stat_t)
		if !ok || int(st.Uid) != os.Getuid() || info.Mode().Perm()&0o077 != 0 {
			return nil, Stop("input_file_must_be_private")
		}
	}
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, Stop("unreadable_or_invalid_json")
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, maxBytes+1))
	if err != nil || int64(len(raw)) > maxBytes {
		return nil, Stop("unreadable_or_invalid_json")
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var out map[string]any
	if err := dec.Decode(&out); err != nil || out == nil {
		return nil, Stop("unreadable_or_invalid_json")
	}
	// Ensure no trailing garbage tokens.
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		return nil, Stop("unreadable_or_invalid_json")
	}
	return out, nil
}

func WithLock(path string, fn func() error) error {
	fd, err := syscall.Open(path, syscall.O_RDWR|syscall.O_CREAT|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0o600)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	if err := syscall.Fchmod(fd, 0o600); err != nil {
		return err
	}
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return Stop("operation_or_route_busy")
		}
		return err
	}
	return fn()
}

func asString(v any) (string, bool) {
	s, ok := v.(string)
	return s, ok
}

func asMap(v any) (map[string]any, bool) {
	m, ok := v.(map[string]any)
	return m, ok
}

func asSlice(v any) ([]any, bool) {
	s, ok := v.([]any)
	return s, ok
}

func asBool(v any) (bool, bool) {
	b, ok := v.(bool)
	return b, ok
}

func asInt64(v any) (int64, bool) {
	switch n := v.(type) {
	case int:
		return int64(n), true
	case int64:
		return n, true
	case json.Number:
		i, err := n.Int64()
		return i, err == nil
	case float64:
		if float64(int64(n)) == n {
			return int64(n), true
		}
		return 0, false
	default:
		return 0, false
	}
}

func jsonEqual(a, b any) bool {
	ea, err1 := Encode(a)
	eb, err2 := Encode(b)
	return err1 == nil && err2 == nil && bytes.Equal(ea, eb)
}

func fmtErr(err error) (outcome, reason string) {
	var se *StopError
	if errors.As(err, &se) {
		return se.Outcome, se.Reason
	}
	return "failed", fmt.Sprintf("internal_or_storage_error")
}
