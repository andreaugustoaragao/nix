package chatsend

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

type AttachmentSource struct {
	Path string
	Name string
}

type Block struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

func RouteConfig(path, alias string) (map[string]any, error) {
	if !TokenRe.MatchString(alias) {
		return nil, Stop("invalid_route_alias")
	}
	cfg, err := ReadJSON(path, true)
	if err != nil {
		return nil, err
	}
	ver, ok := asInt64(cfg["version"])
	routes, rok := asMap(cfg["routes"])
	if !ok || ver != 1 || !rok {
		return nil, Stop("invalid_routes")
	}
	route, ok := asMap(routes[alias])
	if !ok {
		return nil, Stop("route_missing_or_invalid")
	}
	required := []string{"url", "title", "account", "account_label"}
	for _, k := range required {
		if _, exists := route[k]; !exists {
			return nil, Stop("route_missing_or_invalid")
		}
	}
	for k, v := range route {
		if k != "url" && k != "title" && k != "account" && k != "account_label" && k != "kind" {
			return nil, Stop("route_missing_or_invalid")
		}
		s, sok := asString(v)
		if !sok || len(s) == 0 || len(s) >= 2048 {
			return nil, Stop("invalid_route_values")
		}
	}
	rawURL, _ := asString(route["url"])
	account, _ := asString(route["account"])
	accountLabel, _ := asString(route["account_label"])
	if !ChatURLRe.MatchString(rawURL) || !EmailRe.MatchString(account) {
		return nil, Stop("noncanonical_route_or_account")
	}
	if !strings.HasPrefix(accountLabel, "Google Account:") || !strings.HasSuffix(accountLabel, "("+account+")") {
		return nil, Stop("invalid_account_label")
	}
	if kind, exists := route["kind"]; exists {
		ks, _ := asString(kind)
		if ks != "dm" && ks != "group" {
			return nil, Stop("invalid_route_kind")
		}
	}
	return route, nil
}

func AttachmentName(path string) (string, error) {
	if !strings.HasPrefix(path, "/") {
		return "", Stop("invalid_attachment_name", "failed")
	}
	name := filepath.Base(path)
	raw := []byte(name)
	if len(raw) < 1 || len(raw) > 180 || name == "." || name == ".." {
		return "", Stop("invalid_attachment_name", "failed")
	}
	for _, b := range raw {
		if b < 32 || b == 127 {
			return "", Stop("invalid_attachment_name", "failed")
		}
	}
	return name, nil
}

func openSource(path string) (int, fileIdentity, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return -1, fileIdentity{}, Stop("attachment_source_unavailable", "failed")
	}
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		_ = syscall.Close(fd)
		return -1, fileIdentity{}, Stop("attachment_source_unavailable", "failed")
	}
	mode := st.Mode & syscall.S_IFMT
	if mode == syscall.S_IFIFO {
		_ = syscall.Close(fd)
		return -1, fileIdentity{}, Stop("attachment_source_unavailable", "failed")
	}
	if mode != syscall.S_IFREG || st.Size < 1 || st.Size > MaxAttachment {
		_ = syscall.Close(fd)
		return -1, fileIdentity{}, Stop("attachment_source_invalid", "failed")
	}
	return fd, statIdentity(&st), nil
}

func StageAttachment(source, destination string) (map[string]any, error) {
	parent := filepath.Dir(destination)
	if _, err := PrivateDir(parent); err != nil {
		return nil, err
	}
	fd, before, err := openSource(source)
	if err != nil {
		return nil, err
	}
	defer syscall.Close(fd)

	tmp, err := os.CreateTemp(parent, ".attachment-*")
	if err != nil {
		return nil, Stop("attachment_source_unavailable", "failed")
	}
	tmpName := tmp.Name()
	cleanupTmp := true
	defer func() {
		if cleanupTmp {
			_ = os.Remove(tmpName)
		}
	}()
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return nil, err
	}

	hasher := sha256.New()
	buf := make([]byte, 1024*1024)
	var copied int64
	for {
		n, rerr := syscall.Read(fd, buf)
		if n > 0 {
			chunk := buf[:n]
			_, _ = hasher.Write(chunk)
			if _, werr := tmp.Write(chunk); werr != nil {
				_ = tmp.Close()
				return nil, werr
			}
			copied += int64(n)
			if copied > MaxAttachment {
				_ = tmp.Close()
				_ = os.Remove(destination)
				return nil, Stop("attachment_too_large", "failed")
			}
		}
		if n == 0 && rerr == nil {
			break
		}
		if rerr != nil {
			if rerr == syscall.EINTR {
				continue
			}
			_ = tmp.Close()
			return nil, Stop("attachment_source_unavailable", "failed")
		}
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return nil, err
	}
	if err := tmp.Close(); err != nil {
		return nil, err
	}

	var extra [1]byte
	en, _ := syscall.Read(fd, extra[:])
	var after syscall.Stat_t
	if err := syscall.Fstat(fd, &after); err != nil || copied != before.size || en != 0 || statIdentity(&after) != before {
		_ = os.Remove(destination)
		return nil, Stop("attachment_source_changed", "failed")
	}
	if err := os.Rename(tmpName, destination); err != nil {
		return nil, err
	}
	cleanupTmp = false
	if err := syncDir(parent); err != nil {
		return nil, err
	}
	if err := os.Chmod(destination, 0o600); err != nil {
		return nil, err
	}
	return map[string]any{
		"name":   filepath.Base(destination),
		"size":   copied,
		"sha256": hex.EncodeToString(hasher.Sum(nil)),
	}, nil
}

func SnapshotValid(path string, expected map[string]any) error {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return Stop("attachment_snapshot_invalid", "failed")
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		return Stop("attachment_snapshot_invalid", "failed")
	}
	expSize, okSize := asInt64(expected["size"])
	expHash, okHash := asString(expected["sha256"])
	expName, okName := asString(expected["name"])
	if !okSize || !okHash || !okName {
		return Stop("attachment_snapshot_invalid", "failed")
	}
	if (st.Mode&syscall.S_IFMT) != syscall.S_IFREG || int(st.Uid) != os.Getuid() || (st.Mode&0o777) != 0o600 || st.Size != expSize {
		return Stop("attachment_snapshot_invalid", "failed")
	}
	hasher := sha256.New()
	if _, err := io.CopyBuffer(hasher, f, make([]byte, 1024*1024)); err != nil {
		return Stop("attachment_snapshot_invalid", "failed")
	}
	if hex.EncodeToString(hasher.Sum(nil)) != expHash || filepath.Base(path) != expName {
		return Stop("attachment_snapshot_invalid", "failed")
	}
	return nil
}

func PayloadParts(path string, cliAttachments []string) (map[string]any, string, []map[string]any, []AttachmentSource, error) {
	payload, err := ReadJSON(path, false)
	if err != nil {
		return nil, "", nil, nil, err
	}
	ver, vok := asInt64(payload["version"])
	if !vok || ver != 1 {
		return nil, "", nil, nil, Stop("invalid_payload")
	}
	for k := range payload {
		switch k {
		case "version", "blocks", "operation_id", "mention", "attachments":
		default:
			return nil, "", nil, nil, Stop("invalid_payload")
		}
	}
	blocksRaw, bok := asSlice(payload["blocks"])
	if !bok || len(blocksRaw) < 1 || len(blocksRaw) > 60 {
		return nil, "", nil, nil, Stop("invalid_blocks")
	}
	rendered := make([]string, 0, len(blocksRaw)+1)
	expected := make([]map[string]any, 0, len(blocksRaw)+1)
	for _, item := range blocksRaw {
		block, ok := asMap(item)
		if !ok {
			return nil, "", nil, nil, Stop("invalid_block")
		}
		kind, kok := asString(block["type"])
		if !kok || (kind != "text" && kind != "code") {
			return nil, "", nil, nil, Stop("invalid_block")
		}
		for k := range block {
			if k != "type" && k != "text" && !(kind == "code" && k == "language") {
				return nil, "", nil, nil, Stop("invalid_block_text")
			}
		}
		val, valOK := asString(block["text"])
		if !valOK || val == "" || strings.ContainsAny(val, "\r\x00") || strings.Contains(val, Marker) {
			return nil, "", nil, nil, Stop("invalid_block_text")
		}
		if kind == "code" {
			lang := ""
			if rawLang, exists := block["language"]; exists {
				ls, lok := asString(rawLang)
				if !lok {
					return nil, "", nil, nil, Stop("invalid_code_fence")
				}
				lang = ls
			}
			if !LangRe.MatchString(lang) || strings.Contains(val, "```") {
				return nil, "", nil, nil, Stop("invalid_code_fence")
			}
			rendered = append(rendered, "```\n"+val+"\n```")
		} else {
			lines := strings.Split(val, "\n")
			kept := make([]string, 0, len(lines))
			for _, line := range lines {
				if line != Signature {
					kept = append(kept, line)
				}
			}
			val = strings.Trim(strings.Join(kept, "\n"), "\n")
			if val == "" {
				continue
			}
			if strings.Contains(val, Signature) || strings.Contains(val, "```") {
				return nil, "", nil, nil, Stop("signature_or_code_must_be_a_separate_block")
			}
			rendered = append(rendered, val)
		}
		expected = append(expected, map[string]any{"type": kind, "text": val})
	}
	if len(expected) == 0 {
		return nil, "", nil, nil, Stop("empty_message")
	}
	rendered = append(rendered, Marker+Signature)
	expected = append(expected, map[string]any{"type": "text", "text": Signature})
	text := strings.Join(rendered, "\n\n")
	if len(text) > 30000 {
		return nil, "", nil, nil, Stop("message_too_large")
	}

	if rawMention, exists := payload["mention"]; exists && rawMention != nil {
		mention, ok := asMap(rawMention)
		if !ok {
			return nil, "", nil, nil, Stop("invalid_mention")
		}
		for k, v := range mention {
			if k != "email" && k != "query" && k != "user_id" && k != "member_id" {
				return nil, "", nil, nil, Stop("invalid_mention")
			}
			s, sok := asString(v)
			if !sok || len(s) == 0 || len(s) >= 200 {
				return nil, "", nil, nil, Stop("invalid_mention")
			}
		}
		email, eok := asString(mention["email"])
		query, qok := asString(mention["query"])
		if !eok || !qok {
			return nil, "", nil, nil, Stop("invalid_mention")
		}
		if !EmailRe.MatchString(email) || !QueryRe.MatchString(query) {
			return nil, "", nil, nil, Stop("invalid_mention_identity_or_query")
		}
	}

	suppliedRaw, hasSupplied := payload["attachments"]
	if len(cliAttachments) > 0 && hasSupplied && suppliedRaw != nil {
		return nil, "", nil, nil, Stop("attachments_supplied_twice", "failed")
	}
	var suppliedPaths []string
	if len(cliAttachments) > 0 {
		suppliedPaths = cliAttachments
	} else if hasSupplied && suppliedRaw != nil {
		arr, ok := asSlice(suppliedRaw)
		if !ok || len(arr) != 1 {
			return nil, "", nil, nil, Stop("invalid_attachments", "failed")
		}
		suppliedPaths = make([]string, 0, len(arr))
		for _, item := range arr {
			m, mok := asMap(item)
			if !mok || len(m) != 1 {
				return nil, "", nil, nil, Stop("invalid_attachments", "failed")
			}
			p, pok := asString(m["path"])
			if !pok {
				return nil, "", nil, nil, Stop("invalid_attachments", "failed")
			}
			suppliedPaths = append(suppliedPaths, p)
		}
	}

	var sources []AttachmentSource
	if suppliedPaths != nil {
		if len(suppliedPaths) != 1 {
			return nil, "", nil, nil, Stop("invalid_attachments", "failed")
		}
		seen := make(map[string]struct{}, len(suppliedPaths))
		sources = make([]AttachmentSource, 0, len(suppliedPaths))
		for _, p := range suppliedPaths {
			name, nerr := AttachmentName(p)
			if nerr != nil {
				return nil, "", nil, nil, nerr
			}
			if _, dup := seen[name]; dup {
				return nil, "", nil, nil, Stop("duplicate_attachment_name", "failed")
			}
			seen[name] = struct{}{}
			sources = append(sources, AttachmentSource{Path: p, Name: name})
		}
	}

	return payload, text, NormalizeBlocks(expected), sources, nil
}

func NormalizeBlocks(blocks []map[string]any) []map[string]any {
	result := make([]map[string]any, 0, len(blocks))
	for _, block := range blocks {
		kind, _ := asString(block["type"])
		val, _ := asString(block["text"])
		if kind == "text" {
			lines := strings.Split(val, "\n")
			for i, line := range lines {
				if line == Marker+Signature {
					lines[i] = Signature
				}
			}
			val = strings.Trim(MultiNewlineRe.ReplaceAllString(strings.Join(lines, "\n"), "\n\n"), "\n")
			if val == "" {
				continue
			}
		}
		if len(result) > 0 && kind == "text" && result[len(result)-1]["type"] == "text" {
			prev, _ := asString(result[len(result)-1]["text"])
			result[len(result)-1]["text"] = prev + "\n\n" + val
		} else {
			result = append(result, map[string]any{"type": kind, "text": val})
		}
	}
	return result
}

func Matching(body map[string]any, expected []map[string]any, mention map[string]any, published bool) bool {
	if body == nil {
		return false
	}
	if f, _ := asBool(body["forbidden"]); f {
		return false
	}
	if sl, _ := asBool(body["signature_list"]); sl {
		return false
	}
	if sp, ok := asBool(body["signature_plain"]); !ok || !sp {
		return false
	}
	rawBlocks, ok := asSlice(body["blocks"])
	if !ok {
		return false
	}
	blocks := make([]map[string]any, 0, len(rawBlocks))
	for _, b := range rawBlocks {
		m, mok := asMap(b)
		if !mok {
			return false
		}
		cp := make(map[string]any, len(m))
		for k, v := range m {
			cp[k] = v
		}
		blocks = append(blocks, cp)
	}

	var chips []any
	if rawChips, exists := body["mentions"]; exists && rawChips != nil {
		c, cok := asSlice(rawChips)
		if !cok {
			return false
		}
		chips = c
	}
	if mention == nil {
		if len(chips) > 0 {
			return false
		}
	} else {
		if len(chips) != 1 {
			return false
		}
		chip, cok := asMap(chips[0])
		if !cok {
			return false
		}
		sel, sok := asBool(chip["selected"])
		if !sok || !sel || chip["email"] != mention["email"] {
			return false
		}
		uid, _ := asString(chip["user_id"])
		mid, _ := asString(chip["member_id"])
		if uid == "" || mid == "" {
			return false
		}
		wantType := "0"
		if published {
			wantType = "3"
		}
		if chip["mention_type"] != wantType {
			return false
		}
		for _, k := range []string{"user_id", "member_id"} {
			if mv, exists := mention[k]; exists && chip[k] != mv {
				return false
			}
		}
		for len(blocks) > 0 && blocks[0]["type"] == "text" {
			t, _ := asString(blocks[0]["text"])
			if strings.Trim(t, "\n"+Marker) != "" {
				break
			}
			blocks = blocks[1:]
		}
		if len(blocks) == 0 || blocks[0]["type"] != "mention" {
			return false
		}
		blocks = blocks[1:]
		if len(blocks) > 0 && blocks[0]["type"] == "text" {
			t, _ := asString(blocks[0]["text"])
			t = strings.TrimLeft(t, Marker)
			if !strings.HasPrefix(t, " ") {
				return false
			}
			blocks[0]["text"] = strings.TrimLeft(t[1:], Marker)
		}
	}
	for _, b := range blocks {
		t, tok := asString(b["type"])
		_, txtOK := asString(b["text"])
		if !tok || (t != "text" && t != "code") || !txtOK {
			return false
		}
	}
	return jsonEqual(NormalizeBlocks(blocks), expected)
}

func Empty(body map[string]any, dom map[string]any) bool {
	if body == nil {
		return false
	}
	txt, _ := asString(body["text"])
	if strings.Trim(txt, "\n") != "" {
		return false
	}
	if rawM, exists := body["mentions"]; exists && rawM != nil {
		if m, ok := asSlice(rawM); ok && len(m) > 0 {
			return false
		}
	}
	if f, _ := asBool(body["forbidden"]); f {
		return false
	}
	if rawBlocks, exists := body["blocks"]; exists && rawBlocks != nil {
		blocks, ok := asSlice(rawBlocks)
		if !ok {
			return false
		}
		for _, item := range blocks {
			b, bok := asMap(item)
			if !bok {
				return false
			}
			bt, _ := asString(b["type"])
			btxt, _ := asString(b["text"])
			if bt != "text" || strings.Trim(btxt, "\n") != "" {
				return false
			}
		}
	}
	if dom == nil {
		return true
	}
	att, ok := asSlice(dom["composer_attachments"])
	return ok && len(att) == 0
}
