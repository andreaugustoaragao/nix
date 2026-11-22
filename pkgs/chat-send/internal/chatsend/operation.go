package chatsend

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

type Options struct {
	Mode       string // "", "status", "cancel"
	Route      string
	Message    string
	Send       bool
	Operation  string
	Attach     []string
	RoutesFile string
	StateDir   string
	Runner     BrowserRunner
	ProbeJS    string
	FastTests  bool
}

type Operation struct {
	Root      string
	Directory string
	Path      string
	Record    map[string]any
	Browser   *Browser
	OwnerPath string
	Reloaded  bool
	FastTests bool
}

func NewOperation(root, operationID string, runner BrowserRunner, probeJS string, fast bool) (*Operation, error) {
	dir, err := PrivateDir(filepath.Join(root, operationID))
	if err != nil {
		return nil, err
	}
	receiptPath := filepath.Join(dir, "receipt.json")
	var record map[string]any
	if _, statErr := os.Stat(receiptPath); statErr == nil {
		rec, rerr := ReadReceiptJSON(receiptPath)
		if rerr != nil {
			return nil, rerr
		}
		record = rec
	} else {
		record = map[string]any{"operation_id": operationID}
	}
	op := &Operation{
		Root:      root,
		Directory: dir,
		Path:      receiptPath,
		Record:    record,
		FastTests: fast,
	}
	op.Browser = &Browser{
		Record:  op.Record,
		Persist: op.Save,
		Runner:  runner,
		ProbeJS: probeJS,
	}
	if req, ok := asMap(record["request"]); ok {
		if route, rok := asMap(req["route"]); rok {
			if rawURL, uok := asString(route["url"]); uok {
				if key, kerr := RouteKey(rawURL); kerr == nil {
					op.OwnerPath = filepath.Join(root, "route-"+key+".json")
				}
			}
		}
	}
	return op, nil
}

func (o *Operation) Save() error {
	data, err := Encode(o.Record)
	if err != nil {
		return err
	}
	if int64(len(data)) > MaxReceiptBytes {
		return Stop("receipt_too_large", "failed")
	}
	return AtomicWriteJSON(o.Path, o.Record)
}

func (o *Operation) stagedBindings(sources []AttachmentSource) ([]any, error) {
	attRoot, err := PrivateDir(filepath.Join(o.Directory, "attachments"))
	if err != nil {
		return nil, err
	}
	staged := make([]any, 0, len(sources))
	var total int64
	for idx, src := range sources {
		parent, perr := PrivateDir(filepath.Join(attRoot, strconv.Itoa(idx)))
		if perr != nil {
			_ = os.RemoveAll(attRoot)
			return nil, perr
		}
		item, serr := StageAttachment(src.Path, filepath.Join(parent, src.Name))
		if serr != nil {
			_ = os.RemoveAll(attRoot)
			return nil, serr
		}
		item["index"] = idx
		item["source"] = src.Path
		sz, _ := asInt64(item["size"])
		total += sz
		if total > MaxAttachment {
			_ = os.RemoveAll(attRoot)
			return nil, Stop("attachment_too_large", "failed")
		}
		staged = append(staged, item)
	}
	return staged, nil
}

func (o *Operation) revalidateSnapshots() error {
	req, _ := asMap(o.Record["request"])
	atts, ok := asSlice(req["attachments"])
	if !ok {
		return nil
	}
	for _, raw := range atts {
		item, iok := asMap(raw)
		if !iok {
			return Stop("attachment_snapshot_invalid", "failed")
		}
		idx, _ := asInt64(item["index"])
		name, _ := asString(item["name"])
		snapPath := filepath.Join(o.Directory, "attachments", strconv.FormatInt(idx, 10), name)
		if err := SnapshotValid(snapPath, item); err != nil {
			return err
		}
	}
	return nil
}

func (o *Operation) Bind(request map[string]any, sources []AttachmentSource) error {
	if existingReq, exists := asMap(o.Record["request"]); exists {
		current := make(map[string]any, len(existingReq))
		for k, v := range existingReq {
			if k != "attachments" {
				current[k] = v
			}
		}
		fp, err := Digest(existingReq)
		if err != nil || !jsonEqual(current, request) || o.Record["fingerprint"] != fp {
			return Stop("operation_id_payload_or_route_changed")
		}
		bound, _ := asSlice(existingReq["attachments"])
		if len(bound) != len(sources) {
			return Stop("operation_id_payload_or_route_changed")
		}
		for i, src := range sources {
			item, ok := asMap(bound[i])
			if !ok || item["source"] != src.Path || item["name"] != src.Name {
				return Stop("operation_id_payload_or_route_changed")
			}
		}
		if len(sources) > 0 {
			return o.revalidateSnapshots()
		}
		return nil
	}
	if len(sources) > 0 {
		staged, err := o.stagedBindings(sources)
		if err != nil {
			return err
		}
		reqCopy := make(map[string]any, len(request)+1)
		for k, v := range request {
			reqCopy[k] = v
		}
		reqCopy["attachments"] = staged
		request = reqCopy
	}
	fp, err := Digest(request)
	if err != nil {
		return err
	}
	o.Record["request"] = request
	o.Record["fingerprint"] = fp
	o.Record["outcome"] = "preview"
	o.Record["reason"] = "prepared"
	return o.Save()
}

func (o *Operation) Reserve() error {
	req, _ := asMap(o.Record["request"])
	route, _ := asMap(req["route"])
	rawURL, _ := asString(route["url"])
	key, err := RouteKey(rawURL)
	if err != nil {
		return err
	}
	o.OwnerPath = filepath.Join(o.Root, "route-"+key+".json")
	if _, statErr := os.Stat(o.OwnerPath); statErr == nil {
		owner, rerr := ReadJSON(o.OwnerPath, true)
		if rerr != nil {
			return rerr
		}
		if owner["operation_id"] != o.Record["operation_id"] {
			return Stop("route_owned_by_another_operation")
		}
		return nil
	}
	return AtomicWriteJSON(o.OwnerPath, map[string]any{"operation_id": o.Record["operation_id"]})
}

func (o *Operation) Release() error {
	if o.OwnerPath == "" {
		return nil
	}
	if _, statErr := os.Stat(o.OwnerPath); statErr != nil {
		return nil
	}
	owner, err := ReadJSON(o.OwnerPath, true)
	if err != nil {
		return err
	}
	if owner["operation_id"] == o.Record["operation_id"] {
		return os.Remove(o.OwnerPath)
	}
	return nil
}

func (o *Operation) Checked() (map[string]any, error) {
	dom, err := o.Browser.Probe()
	if err != nil {
		return nil, err
	}
	req, _ := asMap(o.Record["request"])
	route, _ := asMap(req["route"])
	if dom["url"] != route["url"] || dom["title"] != route["title"] {
		return nil, Stop("route_or_title_changed")
	}
	rawAccounts, _ := asSlice(dom["accounts"])
	accounts := make([]string, 0, len(rawAccounts))
	for _, item := range rawAccounts {
		if s, ok := asString(item); ok {
			accounts = append(accounts, NormalizeSpace(s))
		}
	}
	wantLabel, _ := asString(route["account_label"])
	if len(accounts) != 1 || accounts[0] != NormalizeSpace(wantLabel) {
		return nil, Stop("account_changed_or_ambiguous")
	}
	editors, eok := asSlice(dom["editors"])
	if !eok || len(editors) != 1 {
		return nil, Stop("composer_missing_or_ambiguous")
	}
	ed0, edOK := asMap(editors[0])
	if !edOK || ed0["name"] != EditorTarget["name"] {
		return nil, Stop("composer_missing_or_ambiguous")
	}
	sendCount, scOK := asInt64(dom["send_count"])
	if !scOK || sendCount != 1 {
		return nil, Stop("send_control_missing_or_ambiguous")
	}
	if dialogs, dok := asInt64(dom["dialogs"]); dok && dialogs != 0 {
		return nil, Stop("dialog_requires_attention")
	}
	if dom["composer_boundary"] != "supported" {
		return nil, Stop("composer_boundary_unsupported")
	}
	if _, aok := asSlice(dom["composer_attachments"]); !aok {
		return nil, Stop("composer_boundary_unsupported")
	}
	return dom, nil
}

func (o *Operation) expectedBlocks() []map[string]any {
	req, _ := asMap(o.Record["request"])
	if typed, ok := req["expected"].([]map[string]any); ok {
		return typed
	}
	raw, _ := asSlice(req["expected"])
	out := make([]map[string]any, 0, len(raw))
	for _, item := range raw {
		if m, ok := asMap(item); ok {
			out = append(out, m)
		}
	}
	return out
}

func (o *Operation) payloadMention() map[string]any {
	req, _ := asMap(o.Record["request"])
	payload, _ := asMap(req["payload"])
	m, _ := asMap(payload["mention"])
	return m
}

func (o *Operation) Expected(body map[string]any, published bool) bool {
	return Matching(body, o.expectedBlocks(), o.payloadMention(), published)
}

func (o *Operation) settleDuration(normal time.Duration) time.Duration {
	if o.FastTests {
		return 1 * time.Second
	}
	return normal
}

func (o *Operation) Settle(publication, bodyOnly bool) (map[string]any, map[string]any, error) {
	deadline := time.Now().Add(o.settleDuration(12 * time.Second))
	for {
		dom, err := o.Checked()
		if err != nil {
			return nil, nil, err
		}
		if publication {
			found, perr := o.Publication(dom, false)
			if perr != nil {
				return nil, nil, perr
			}
			if found != nil {
				return dom, found, nil
			}
		} else {
			editors, _ := asSlice(dom["editors"])
			ed0, _ := asMap(editors[0])
			var ready bool
			if bodyOnly {
				ready = Matching(ed0, o.expectedBlocks(), nil, false)
			} else {
				ready = o.Expected(ed0, false)
			}
			if ready {
				return dom, nil, nil
			}
		}
		if !time.Now().Before(deadline) {
			if publication {
				refreshed, rerr := o.RefreshPublication(dom)
				if rerr != nil {
					return nil, nil, rerr
				}
				if refreshed {
					deadline = time.Now().Add(o.settleDuration(12 * time.Second))
					continue
				}
				return nil, nil, Stop("publication_not_confirmed", "uncertain")
			}
			return nil, nil, Stop("markdown_did_not_settle")
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func (o *Operation) Mention() error {
	mention := o.payloadMention()
	if attempted, _ := asBool(o.Record["mention_attempted"]); attempted {
		return Stop("mention_composition_interrupted")
	}
	o.Record["mention_attempted"] = true
	if err := o.Save(); err != nil {
		return err
	}
	if _, err := o.Browser.Action("click", "", map[string]any{"target": EditorTarget}); err != nil {
		return err
	}
	query, _ := asString(mention["query"])
	email, _ := asString(mention["email"])
	keys := []string{"Control+Home", "Space", "ArrowLeft", "@"}
	for _, r := range query {
		keys = append(keys, string(r))
	}
	for _, k := range keys {
		if _, err := o.Browser.Action("key", "", map[string]any{"key": k}); err != nil {
			return err
		}
	}
	deadline := time.Now().Add(o.settleDuration(6 * time.Second))
	for {
		dom, err := o.Checked()
		if err != nil {
			return err
		}
		optsRaw, _ := asSlice(dom["options"])
		var matched []map[string]any
		for _, raw := range optsRaw {
			opt, ok := asMap(raw)
			if !ok {
				continue
			}
			name, _ := asString(opt["name"])
			if name != "" && containsString(name, email) {
				matched = append(matched, opt)
			}
		}
		if len(matched) > 1 {
			return Stop("mention_option_ambiguous")
		}
		if len(matched) == 1 {
			opt := matched[0]
			if opt["email"] != email || opt["id"] != email || opt["chip_type"] != "2" {
				return Stop("mention_option_identity_changed")
			}
			break
		}
		if !time.Now().Before(deadline) {
			return Stop("real_mention_option_unavailable")
		}
		time.Sleep(200 * time.Millisecond)
	}
	if _, err := o.Browser.Action("click", "", map[string]any{
		"target": map[string]any{"role": "option", "name": email, "exact": false},
	}); err != nil {
		return err
	}
	if _, _, err := o.Settle(false, false); err != nil {
		return err
	}
	o.Record["mention_inserted"] = true
	return o.Save()
}

func containsString(haystack, needle string) bool {
	if needle == "" {
		return true
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}

func (o *Operation) AttachmentNames() []string {
	req, _ := asMap(o.Record["request"])
	atts, ok := asSlice(req["attachments"])
	if !ok {
		return nil
	}
	out := make([]string, 0, len(atts))
	for _, raw := range atts {
		if m, mok := asMap(raw); mok {
			if name, nok := asString(m["name"]); nok {
				out = append(out, name)
			}
		}
	}
	return out
}

func (o *Operation) AttachmentSettled(observed []any) bool {
	expected := o.AttachmentNames()
	if observed == nil {
		return false
	}
	if len(observed) != len(expected) {
		return false
	}
	for i, raw := range observed {
		item, ok := asMap(raw)
		if !ok {
			return false
		}
		name, _ := asString(item["name"])
		pending, pok := asBool(item["pending"])
		errFlag, eok := asBool(item["error"])
		if name != expected[i] || !pok || pending || !eok || errFlag {
			return false
		}
	}
	return true
}

func (o *Operation) PublishedAttachments(message map[string]any) bool {
	expected := o.AttachmentNames()
	rawObs, exists := message["attachments"]
	if !exists || rawObs == nil {
		return false
	}
	observed, ok := asSlice(rawObs)
	if !ok {
		return false
	}
	if len(expected) == 0 {
		return len(observed) == 0
	}
	if len(observed) != len(expected) {
		return false
	}
	for i, raw := range observed {
		item, iok := asMap(raw)
		if !iok {
			return false
		}
		name, _ := asString(item["name"])
		pending, pok := asBool(item["pending"])
		errFlag, eok := asBool(item["error"])
		if name != expected[i] || !pok || pending || !eok || errFlag {
			return false
		}
	}
	return true
}

func (o *Operation) Publication(dom map[string]any, localOnly bool) (map[string]any, error) {
	baselineRaw, _ := asSlice(o.Record["baseline_ids"])
	if len(baselineRaw) == 0 {
		return nil, nil
	}
	own, _ := asString(o.Record["sender_id"])
	idsRaw, _ := asSlice(dom["message_ids"])
	editors, _ := asSlice(dom["editors"])
	if len(editors) == 0 {
		return nil, nil
	}
	ed0, _ := asMap(editors[0])
	if !Empty(ed0, dom) {
		return nil, nil
	}
	baselineSet := make(map[string]struct{}, len(baselineRaw))
	var lastBaseline string
	for _, raw := range baselineRaw {
		if s, ok := asString(raw); ok {
			baselineSet[s] = struct{}{}
			lastBaseline = s
		}
	}
	tail := -1
	for i, raw := range idsRaw {
		if s, ok := asString(raw); ok && s == lastBaseline {
			tail = i
			break
		}
	}
	if tail < 0 {
		return nil, nil
	}
	afterSet := make(map[string]struct{}, len(idsRaw)-tail-1)
	for _, raw := range idsRaw[tail+1:] {
		if s, ok := asString(raw); ok {
			afterSet[s] = struct{}{}
		}
	}
	msgsRaw, _ := asSlice(dom["messages"])
	var matches []map[string]any
	for _, raw := range msgsRaw {
		m, ok := asMap(raw)
		if !ok {
			continue
		}
		id, _ := asString(m["id"])
		if _, inAfter := afterSet[id]; !inAfter {
			continue
		}
		if _, inBase := baselineSet[id]; inBase {
			continue
		}
		if m["sender_id"] != own {
			continue
		}
		bc, bcOK := asInt64(m["body_count"])
		if !bcOK || bc != 1 {
			continue
		}
		body, _ := asMap(m["body"])
		if !o.Expected(body, true) || !o.PublishedAttachments(m) {
			continue
		}
		matches = append(matches, m)
	}
	if len(matches) > 1 {
		return nil, Stop("multiple_new_matching_messages", "uncertain")
	}
	if len(matches) == 0 {
		return nil, nil
	}
	msg := matches[0]
	obsRaw, _ := asSlice(msg["attachments"])
	diagAtts := make([]any, 0, len(obsRaw))
	for _, raw := range obsRaw {
		if item, ok := asMap(raw); ok {
			diagAtts = append(diagAtts, map[string]any{
				"name":    item["name"],
				"pending": item["pending"],
				"error":   item["error"],
			})
		}
	}
	o.Record["publication_diagnostics"] = map[string]any{
		"id":          msg["id"],
		"topic_id":    msg["topic_id"],
		"local_only":  msg["local_only"],
		"pending":     msg["pending"],
		"error":       msg["error"],
		"server":      msg["server"],
		"attachments": diagAtts,
	}
	if bound, exists := o.Record["reconciliation_candidate_id"]; exists && bound != nil && msg["id"] != bound {
		return nil, nil
	}
	pFlag, pOK := asBool(msg["pending"])
	eFlag, eOK := asBool(msg["error"])
	if !pOK || pFlag || !eOK || eFlag {
		return nil, nil
	}
	if localOnly {
		lo, _ := asString(msg["local_only"])
		tid, _ := asString(msg["topic_id"])
		if lo == "true" && tid != "" {
			return msg, nil
		}
		return nil, nil
	}
	lo, _ := asString(msg["local_only"])
	srv, srvOK := asBool(msg["server"])
	if lo == "false" && srvOK && srv {
		return msg, nil
	}
	return nil, nil
}

func (o *Operation) RecordUploadObservation(observed []any) error {
	if !o.AttachmentSettled(observed) {
		return Stop("upload_interrupted")
	}
	obs := make([]any, 0, len(observed))
	for _, raw := range observed {
		if item, ok := asMap(raw); ok {
			obs = append(obs, map[string]any{
				"name":    item["name"],
				"pending": item["pending"],
				"error":   item["error"],
			})
		}
	}
	o.Record["upload_observation"] = obs
	return o.Save()
}

func (o *Operation) Upload() error {
	req, _ := asMap(o.Record["request"])
	atts, ok := asSlice(req["attachments"])
	if !ok || len(atts) == 0 {
		return nil
	}
	if attempted, _ := asBool(o.Record["upload_attempted"]); attempted {
		dom, err := o.Checked()
		if err != nil {
			return err
		}
		obs, _ := asSlice(dom["composer_attachments"])
		return o.RecordUploadObservation(obs)
	}
	dom, err := o.Checked()
	if err != nil {
		return err
	}
	fiCount, fiOK := asInt64(dom["file_input_count"])
	existingAtts, _ := asSlice(dom["composer_attachments"])
	if !fiOK || fiCount != 1 || len(existingAtts) > 0 {
		return Stop("file_input_missing_or_ambiguous")
	}
	if err := o.revalidateSnapshots(); err != nil {
		return err
	}
	o.Record["upload_attempted"] = true
	if err := o.Save(); err != nil {
		return err
	}
	paths := make([]string, 0, len(atts))
	for _, raw := range atts {
		item, _ := asMap(raw)
		idx, _ := asInt64(item["index"])
		name, _ := asString(item["name"])
		paths = append(paths, filepath.Join(o.Directory, "attachments", strconv.FormatInt(idx, 10), name))
	}
	if _, err := o.Browser.Action("upload", "", map[string]any{
		"target": map[string]any{"selector": `input[type="file"]`},
		"files":  paths,
	}); err != nil {
		return err
	}
	deadline := time.Now().Add(o.settleDuration(30 * time.Second))
	for {
		cur, cerr := o.Checked()
		if cerr != nil {
			return cerr
		}
		obs, _ := asSlice(cur["composer_attachments"])
		if o.AttachmentSettled(obs) {
			return o.RecordUploadObservation(obs)
		}
		if !time.Now().Before(deadline) {
			return Stop("attachment_upload_did_not_settle")
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func (o *Operation) RemoveOwnedAttachments(owned func(body, current map[string]any, expected []string) bool) error {
	expected := o.AttachmentNames()
	if len(expected) == 0 {
		return nil
	}
	remaining := append([]string(nil), expected...)
	for i := len(expected) - 1; i >= 0; i-- {
		name := expected[i]
		current, err := o.Checked()
		if err != nil {
			return err
		}
		editors, _ := asSlice(current["editors"])
		ed0, _ := asMap(editors[0])
		if !owned(ed0, current, remaining) {
			return Stop("draft_changed_cancel_refused")
		}
		obs, ok := asSlice(current["composer_attachments"])
		if !ok || len(obs) != len(remaining) {
			return Stop("draft_changed_cancel_refused")
		}
		for j, raw := range obs {
			item, iok := asMap(raw)
			if !iok {
				return Stop("draft_changed_cancel_refused")
			}
			n, _ := asString(item["name"])
			rem, rok := asBool(item["removable"])
			if n != remaining[j] || !rok || !rem {
				return Stop("draft_changed_cancel_refused")
			}
		}
		if _, err := o.Browser.Action("click", "", map[string]any{
			"target": map[string]any{"role": "button", "name": "Remove " + name, "exact": true},
		}); err != nil {
			return err
		}
		remaining = remaining[:len(remaining)-1]
	}
	current, err := o.Checked()
	if err != nil {
		return err
	}
	editors, _ := asSlice(current["editors"])
	ed0, _ := asMap(editors[0])
	mentionAttempted, _ := asBool(o.Record["mention_attempted"])
	if !o.Expected(ed0, false) && !(!mentionAttempted && Matching(ed0, o.expectedBlocks(), nil, false)) {
		return Stop("draft_changed_cancel_refused")
	}
	if obs, _ := asSlice(current["composer_attachments"]); len(obs) > 0 {
		return Stop("draft_changed_cancel_refused")
	}
	return nil
}

func (o *Operation) RefreshPublication(dom map[string]any) (bool, error) {
	if reloads, _ := asInt64(o.Record["reconciliation_reloads"]); o.Reloaded || reloads >= 1 {
		return false, nil
	}
	candidate, err := o.Publication(dom, true)
	if err != nil || candidate == nil {
		return false, err
	}
	if err := o.Reserve(); err != nil {
		return false, err
	}
	if err := o.Browser.Ownership(false); err != nil {
		return false, err
	}
	fresh, err := o.Checked()
	if err != nil {
		return false, err
	}
	checked, err := o.Publication(fresh, true)
	if err != nil || checked == nil || checked["id"] != candidate["id"] {
		return false, err
	}
	o.Reloaded = true
	o.Record["reconciliation_candidate_id"] = candidate["id"]
	reloads, _ := asInt64(o.Record["reconciliation_reloads"])
	o.Record["reconciliation_reloads"] = reloads + 1
	if err := o.Save(); err != nil {
		return false, err
	}
	req, _ := asMap(o.Record["request"])
	route, _ := asMap(req["route"])
	if _, err := o.Browser.Action("navigate", "", map[string]any{"url": route["url"]}); err != nil {
		return false, err
	}
	if _, err := o.Browser.Action("wait", "", map[string]any{"target": EditorTarget, "state": "visible"}); err != nil {
		return false, err
	}
	return true, nil
}

func (o *Operation) Screenshot() error {
	res, err := o.Browser.Action("screenshot", "", map[string]any{"full_page": false})
	if err != nil {
		return err
	}
	srcPath, _ := asString(res["path"])
	info, err := os.Lstat(srcPath)
	if err != nil {
		return Stop("invalid_screenshot", "failed")
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.Mode().IsRegular() || int(st.Uid) != os.Getuid() || info.Size() > MaxScreenshotSize {
		return Stop("invalid_screenshot", "failed")
	}
	src, err := os.OpenFile(srcPath, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return Stop("invalid_screenshot", "failed")
	}
	defer src.Close()
	dest := filepath.Join(o.Directory, "screenshot.png")
	tmp, err := os.CreateTemp(o.Directory, ".screenshot-*")
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
	if _, err := io.Copy(tmp, io.LimitReader(src, MaxScreenshotSize+1)); err != nil {
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
	if err := os.Rename(tmpName, dest); err != nil {
		return err
	}
	cleanup = false
	o.Record["screenshot"] = dest
	return o.Save()
}

func (o *Operation) Finish() error {
	if err := o.Browser.Ownership(false); err != nil {
		return err
	}
	taskID, _ := asString(o.Record["task"])
	if _, err := o.Browser.Call([]string{"finish", taskID}, nil, ""); err != nil {
		return err
	}
	o.Record["task_finished"] = true
	return o.Save()
}

func (o *Operation) Confirm(message map[string]any) error {
	o.Record["outcome"] = "sent"
	o.Record["reason"] = "publication_confirmed"
	o.Record["publication_id"] = message["id"]
	o.Record["confirmed_at"] = float64(time.Now().UnixNano()) / 1e9
	if err := o.Save(); err != nil {
		return err
	}
	if err := o.Release(); err != nil {
		return err
	}
	if err := o.Screenshot(); err != nil {
		return err
	}
	return o.Finish()
}

func (o *Operation) Start() error {
	opID, _ := asString(o.Record["operation_id"])
	o.Record["label"] = "chat-send:" + opID
	if err := o.Save(); err != nil {
		return err
	}
	req, _ := asMap(o.Record["request"])
	route, _ := asMap(req["route"])
	rawURL, _ := asString(route["url"])
	task, err := o.Browser.Call([]string{"start", "accounts", "--label", "chat-send:" + opID, "--url", rawURL}, nil, "")
	if err != nil {
		return err
	}
	tid, tok := asString(task["task"])
	pages, pok := asMap(task["pages"])
	if !tok || !pok {
		return Stop("invalid_task_start_response")
	}
	o.Record["task"] = tid
	o.Record["pages"] = pages
	if err := o.Save(); err != nil {
		return err
	}
	if err := o.Browser.Ownership(false); err != nil {
		return err
	}
	if _, err := o.Browser.Action("viewport", "", map[string]any{"width": 1440, "height": 1000}); err != nil {
		return err
	}
	_, err = o.Browser.Action("wait", "", map[string]any{"target": EditorTarget, "state": "visible"})
	return err
}

func (o *Operation) Sender(dom map[string]any) (string, error) {
	req, _ := asMap(o.Record["request"])
	route, _ := asMap(req["route"])
	account, _ := asString(route["account"])
	identRaw, _ := asSlice(dom["identities"])
	ids := make(map[string]struct{})
	for _, raw := range identRaw {
		if m, ok := asMap(raw); ok && m["email"] == account {
			if mid, mok := asString(m["message_id"]); mok {
				ids[mid] = struct{}{}
			}
		}
	}
	msgsRaw, _ := asSlice(dom["messages"])
	senders := make(map[string]struct{})
	for _, raw := range msgsRaw {
		if m, ok := asMap(raw); ok {
			mid, _ := asString(m["id"])
			sid, _ := asString(m["sender_id"])
			if _, in := ids[mid]; in && sid != "" {
				senders[sid] = struct{}{}
			}
		}
	}
	pubSup, _ := asBool(dom["publication_supported"])
	if len(senders) != 1 || !pubSup {
		return "", Stop("publication_identity_not_supported")
	}
	for s := range senders {
		return s, nil
	}
	return "", Stop("publication_identity_not_supported")
}

func (o *Operation) FocusSend() (map[string]any, error) {
	if _, err := o.Browser.Action("click", "", map[string]any{"target": EditorTarget}); err != nil {
		return nil, err
	}
	if _, err := o.Browser.Action("key", "", map[string]any{"key": "Control+End"}); err != nil {
		return nil, err
	}
	dom, err := o.Checked()
	if err != nil {
		return nil, err
	}
	editors, _ := asSlice(dom["editors"])
	ed0, _ := asMap(editors[0])
	obs, _ := asSlice(dom["composer_attachments"])
	edFocused, _ := asBool(dom["editor_focused"])
	caretEnd, _ := asBool(dom["caret_at_plain_end"])
	if !o.Expected(ed0, false) || !o.AttachmentSettled(obs) || !edFocused || !caretEnd {
		return nil, Stop("safe_plain_caret_not_confirmed")
	}
	for i := 0; i < 12; i++ {
		if _, err := o.Browser.Action("key", "", map[string]any{"key": "Tab"}); err != nil {
			return nil, err
		}
		dom, err = o.Checked()
		if err != nil {
			return nil, err
		}
		editors, _ = asSlice(dom["editors"])
		ed0, _ = asMap(editors[0])
		obs, _ = asSlice(dom["composer_attachments"])
		sendEnabled, _ := asBool(dom["send_enabled"])
		if !o.Expected(ed0, false) || !o.AttachmentSettled(obs) || !sendEnabled {
			return nil, Stop("draft_changed_or_send_disabled")
		}
		edFocused, _ = asBool(dom["editor_focused"])
		caretEnd, _ = asBool(dom["caret_at_plain_end"])
		if edFocused && !caretEnd {
			return nil, Stop("safe_plain_caret_not_confirmed")
		}
		if sendFocused, _ := asBool(dom["send_focused"]); sendFocused {
			if err := o.Browser.Ownership(false); err != nil {
				return nil, err
			}
			dom, err = o.Checked()
			if err != nil {
				return nil, err
			}
			editors, _ = asSlice(dom["editors"])
			ed0, _ = asMap(editors[0])
			obs, _ = asSlice(dom["composer_attachments"])
			sf, _ := asBool(dom["send_focused"])
			se, _ := asBool(dom["send_enabled"])
			if !sf || !se || !o.Expected(ed0, false) || !o.AttachmentSettled(obs) {
				return nil, Stop("send_focus_or_draft_changed")
			}
			return dom, nil
		}
	}
	return nil, Stop("send_focus_not_reached")
}

func (o *Operation) Execute(mode string, send bool) error {
	if o.Record["outcome"] == "sent" {
		return o.Release()
	}
	if cancelled, _ := asBool(o.Record["cancelled"]); cancelled {
		if mode != "status" {
			return Stop("operation_cancelled_use_a_new_id")
		}
		return nil
	}
	if attempted, _ := asBool(o.Record["send_attempted"]); attempted {
		taskID, _ := asString(o.Record["task"])
		if taskID == "" {
			return Stop("attempted_task_missing", "uncertain")
		}
		if err := o.Browser.Ownership(true); err != nil {
			return err
		}
		_, msg, err := o.Settle(true, false)
		if err != nil {
			return err
		}
		return o.Confirm(msg)
	}
	if mode == "status" {
		return nil
	}
	req, _ := asMap(o.Record["request"])
	route, _ := asMap(req["route"])
	kind, _ := asString(route["kind"])
	if kind == "" {
		kind = "dm"
	}
	if mode != "cancel" && o.payloadMention() != nil && kind != "group" {
		return Stop("required_dm_mention_unsupported")
	}
	if err := o.Reserve(); err != nil {
		return err
	}
	taskID, _ := asString(o.Record["task"])
	if mode == "cancel" && taskID == "" {
		o.Record["outcome"] = "preview"
		o.Record["reason"] = "cancelled"
		o.Record["cancelled"] = true
		if err := o.Save(); err != nil {
			return err
		}
		return o.Release()
	}
	if taskID == "" {
		if err := o.Start(); err != nil {
			return err
		}
	} else {
		if err := o.Browser.Ownership(true); err != nil {
			return err
		}
	}
	dom, err := o.Checked()
	if err != nil {
		return err
	}
	editors, _ := asSlice(dom["editors"])
	ed0, _ := asMap(editors[0])

	if mode == "cancel" {
		if !Empty(ed0, dom) {
			owned := func(body, current map[string]any, expected []string) bool {
				mentionAttempted, _ := asBool(o.Record["mention_attempted"])
				textOwned := o.Expected(body, false) || (!mentionAttempted && Matching(body, o.expectedBlocks(), nil, false))
				obs, ok := asSlice(current["composer_attachments"])
				if !ok {
					return false
				}
				want := expected
				if want == nil {
					want = o.AttachmentNames()
				}
				if len(obs) != len(want) {
					return false
				}
				for i, raw := range obs {
					item, iok := asMap(raw)
					if !iok {
						return false
					}
					n, _ := asString(item["name"])
					p, pok := asBool(item["pending"])
					e, eok := asBool(item["error"])
					if n != want[i] || !pok || p || !eok || e {
						return false
					}
				}
				return textOwned
			}
			draftWritten, _ := asBool(o.Record["draft_written"])
			if !draftWritten || !owned(ed0, dom, nil) {
				return Stop("draft_changed_cancel_refused")
			}
			fresh, ferr := o.Checked()
			if ferr != nil {
				return ferr
			}
			feds, _ := asSlice(fresh["editors"])
			fed0, _ := asMap(feds[0])
			if !owned(fed0, fresh, nil) {
				return Stop("draft_changed_cancel_refused")
			}
			if err := o.RemoveOwnedAttachments(owned); err != nil {
				return err
			}
			if _, err := o.Browser.Action("fill", "", map[string]any{"target": EditorTarget, "text": ""}); err != nil {
				return err
			}
			cleared, cerr := o.Checked()
			if cerr != nil {
				return cerr
			}
			ceds, _ := asSlice(cleared["editors"])
			ced0, _ := asMap(ceds[0])
			if !Empty(ced0, cleared) {
				return Stop("cancel_clear_not_confirmed")
			}
		}
		if err := o.Finish(); err != nil {
			return err
		}
		o.Record["outcome"] = "preview"
		o.Record["reason"] = "cancelled"
		o.Record["cancelled"] = true
		if err := o.Save(); err != nil {
			return err
		}
		return o.Release()
	}

	if draftWritten, _ := asBool(o.Record["draft_written"]); draftWritten {
		if !o.Expected(ed0, false) {
			mentionAttempted, _ := asBool(o.Record["mention_attempted"])
			if o.payloadMention() != nil && !mentionAttempted && Matching(ed0, o.expectedBlocks(), nil, false) {
				if err := o.Mention(); err != nil {
					return err
				}
			} else {
				return Stop("owned_draft_changed")
			}
		}
	} else if !Empty(ed0, dom) {
		return Stop("foreign_draft")
	} else {
		o.Record["draft_written"] = true
		if err := o.Save(); err != nil {
			return err
		}
		rendered, _ := asString(req["rendered"])
		if _, err := o.Browser.Action("fill", "", map[string]any{"target": EditorTarget, "text": rendered}); err != nil {
			return err
		}
		if _, _, err := o.Settle(false, true); err != nil {
			return err
		}
		if o.payloadMention() != nil {
			if err := o.Mention(); err != nil {
				return err
			}
		}
	}

	if atts, ok := asSlice(req["attachments"]); ok && len(atts) > 0 {
		if upAtt, _ := asBool(o.Record["upload_attempted"]); upAtt {
			cur, cerr := o.Checked()
			if cerr != nil {
				return cerr
			}
			obs, _ := asSlice(cur["composer_attachments"])
			if !o.AttachmentSettled(obs) {
				return Stop("upload_interrupted")
			}
		}
		if err := o.Upload(); err != nil {
			return err
		}
	}

	if !send {
		if err := o.Screenshot(); err != nil {
			return err
		}
		tid, _ := asString(o.Record["task"])
		if _, err := o.Browser.Call([]string{"keep", tid}, nil, ""); err != nil {
			return err
		}
		o.Record["outcome"] = "preview"
		o.Record["reason"] = "ready_for_review"
		return o.Save()
	}

	dom, err = o.Checked()
	if err != nil {
		return err
	}
	editors, _ = asSlice(dom["editors"])
	ed0, _ = asMap(editors[0])
	obs, _ := asSlice(dom["composer_attachments"])
	sendEnabled, _ := asBool(dom["send_enabled"])
	if !o.Expected(ed0, false) || !o.AttachmentSettled(obs) || !sendEnabled {
		return Stop("draft_changed_or_send_disabled")
	}
	dom, err = o.FocusSend()
	if err != nil {
		return err
	}
	senderID, err := o.Sender(dom)
	if err != nil {
		return err
	}
	baseRaw, bok := asSlice(dom["message_ids"])
	seenIDs := make(map[string]struct{}, len(baseRaw))
	for _, raw := range baseRaw {
		s, sok := asString(raw)
		if !sok || s == "" {
			return Stop("publication_ids_ambiguous")
		}
		if _, dup := seenIDs[s]; dup {
			return Stop("publication_ids_ambiguous")
		}
		seenIDs[s] = struct{}{}
	}
	if !bok {
		return Stop("publication_ids_ambiguous")
	}
	o.Record["send_attempted"] = true
	o.Record["submit_method"] = "focused_button_space"
	o.Record["attempted_at"] = float64(time.Now().UnixNano()) / 1e9
	o.Record["baseline_ids"] = baseRaw
	o.Record["sender_id"] = senderID
	o.Record["outcome"] = "uncertain"
	o.Record["reason"] = "send_attempt_recorded"
	if err := o.Save(); err != nil {
		return err
	}
	if _, err := o.Browser.Action("key", "submit", map[string]any{"key": "Space"}); err != nil {
		return err
	}
	_, msg, err := o.Settle(true, false)
	if err != nil {
		return err
	}
	return o.Confirm(msg)
}

func Summary(o *Operation) map[string]any {
	outcome, _ := asString(o.Record["outcome"])
	if outcome == "" {
		outcome = "failed"
	}
	reason, _ := asString(o.Record["reason"])
	if reason == "" {
		reason = "unknown"
	}
	ac, _ := asInt64(o.Record["action_count"])
	am, _ := asInt64(o.Record["action_ms"])
	sa, _ := asBool(o.Record["send_attempted"])
	return map[string]any{
		"outcome":        outcome,
		"reason":         reason,
		"operation_id":   o.Record["operation_id"],
		"receipt":        o.Path,
		"task":           o.Record["task"],
		"action_count":   ac,
		"action_ms":      am,
		"send_attempted": sa,
	}
}

func Run(opts Options) map[string]any {
	var opID string
	var request map[string]any
	var sources []AttachmentSource

	failTop := func(err error, id any) map[string]any {
		outcome, reason := fmtErr(err)
		return map[string]any{"outcome": outcome, "reason": reason, "operation_id": id}
	}

	if opts.Mode != "" {
		if opts.Operation == "" || opts.Route != "" || opts.Message != "" || opts.Send || len(opts.Attach) > 0 {
			return failTop(Stop("status_cancel_require_only_operation"), nullableOp(opts.Operation))
		}
		opID = opts.Operation
	} else {
		if opts.Route == "" || opts.Message == "" {
			return failTop(Stop("route_and_message_required"), nullableOp(opts.Operation))
		}
		if len(opts.Attach) > 1 {
			return failTop(Stop("invalid_attachments", "failed"), nullableOp(opts.Operation))
		}
		route, err := RouteConfig(opts.RoutesFile, opts.Route)
		if err != nil {
			return failTop(err, nullableOp(opts.Operation))
		}
		payload, rendered, expected, srcs, err := PayloadParts(opts.Message, opts.Attach)
		if err != nil {
			return failTop(err, nullableOp(opts.Operation))
		}
		sources = srcs
		var embedded string
		if rawEmb, exists := payload["operation_id"]; exists && rawEmb != nil {
			es, ok := asString(rawEmb)
			if !ok || !TokenRe.MatchString(es) {
				return failTop(Stop("invalid_operation_id"), nullableOp(opts.Operation))
			}
			embedded = es
		}
		if embedded != "" && opts.Operation != "" && embedded != opts.Operation {
			return failTop(Stop("operation_id_disagrees"), nullableOp(opts.Operation))
		}
		if opts.Operation != "" {
			opID = opts.Operation
		} else if embedded != "" {
			opID = embedded
		}
		if opts.Send && opID == "" {
			return failTop(Stop("send_requires_stable_operation_id"), nil)
		}
		if opID == "" {
			var uerr error
			opID, uerr = NewUUIDHex()
			if uerr != nil {
				return failTop(uerr, nil)
			}
		}
		delete(payload, "operation_id")
		delete(payload, "attachments")
		request = map[string]any{
			"alias":    opts.Route,
			"route":    route,
			"payload":  payload,
			"rendered": rendered,
			"expected": expected,
		}
	}

	if !TokenRe.MatchString(opID) {
		return failTop(Stop("invalid_operation_id"), nullableOp(opts.Operation))
	}
	syscall.Umask(0o077)
	root, err := PrivateDir(opts.StateDir)
	if err != nil {
		return failTop(err, opID)
	}

	var result map[string]any
	lockErr := WithLock(filepath.Join(root, opID+".lock"), func() error {
		var op *Operation
		handleErr := func(e error) {
			outcome, reason := fmtErr(e)
			if op == nil {
				result = map[string]any{"outcome": outcome, "reason": reason, "operation_id": opID}
				return
			}
			if reason == "operation_id_payload_or_route_changed" {
				outcome = "needs_attention"
			} else if op.Record["outcome"] == "sent" {
				outcome, reason = "sent", "publication_confirmed_cleanup_incomplete"
			} else if sa, _ := asBool(op.Record["send_attempted"]); sa {
				outcome = "uncertain"
			}
			if reason != "operation_id_payload_or_route_changed" && reason != "operation_cancelled_use_a_new_id" {
				op.Record["outcome"] = outcome
				op.Record["reason"] = reason
				_ = op.Save()
			}
			res := Summary(op)
			res["outcome"] = outcome
			res["reason"] = reason
			result = res
		}

		if request == nil {
			if _, statErr := os.Stat(filepath.Join(root, opID, "receipt.json")); statErr != nil {
				handleErr(Stop("operation_not_found"))
				return nil
			}
		}
		var oerr error
		op, oerr = NewOperation(root, opID, opts.Runner, opts.ProbeJS, opts.FastTests)
		if oerr != nil {
			handleErr(oerr)
			return nil
		}
		if request != nil {
			if berr := op.Bind(request, sources); berr != nil {
				handleErr(berr)
				return nil
			}
		}
		req, _ := asMap(op.Record["request"])
		route, _ := asMap(req["route"])
		rawURL, _ := asString(route["url"])
		rkey, kerr := RouteKey(rawURL)
		if kerr != nil {
			handleErr(kerr)
			return nil
		}
		rlerr := WithLock(filepath.Join(root, "route-"+rkey+".lock"), func() error {
			mode := opts.Mode
			if mode == "" {
				mode = "prepare"
			}
			return op.Execute(mode, opts.Send)
		})
		if rlerr != nil {
			handleErr(rlerr)
			return nil
		}
		result = Summary(op)
		return nil
	})
	if lockErr != nil {
		var se *StopError
		if errors.As(lockErr, &se) {
			return failTop(se, opID)
		}
		return failTop(lockErr, opID)
	}
	return result
}

func nullableOp(op string) any {
	if op == "" {
		return nil
	}
	return op
}
