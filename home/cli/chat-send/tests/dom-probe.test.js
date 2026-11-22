// Execute the actual read-only adapter against narrow DOM fixtures; no browser.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require('node:path').join(__dirname, '../scripts/dom_probe.js'), 'utf8');
if (process.argv.includes('--composer-boundary') || process.argv.includes('--attachment-cases')) require('node:module')._cache;
const messageSelector = '[role="group"][data-id][data-user-id][data-message-multiplat-item-id]';

function probe(dialogs = [], codeText = null) {
  const group = {
    getAttribute: name => ({'data-id': 'old-message', 'data-user-id': 'sender-1'}[name] ?? null),
    closest: () => null, querySelector: () => null, querySelectorAll: () => []
  };
  const elements = dialogs.map(d => ({
    getAttribute: name => ({role: d.role || 'dialog', 'aria-modal': d.modal ?? null}[name] ?? null),
    closest: selector => d.embedded && selector === messageSelector ? group : null,
    getClientRects: () => d.hidden ? [] : [{x: 443, y: -141, width: 320, height: 308}],
    getBoundingClientRect: () => ({left: 10, top: 10, right: 110, bottom: 110})
  }));
  const code = {
    nodeType: 1, tagName: 'ARTICLE', innerText: codeText,
    childNodes: [{nodeType: 3, nodeValue: codeText}],
    matches: selector => selector === 'article[role="code"]'
  };
  const editor = {
    childNodes: [code], getClientRects: () => [{}],
    getAttribute: name => name === 'aria-label' ? 'History is on' : null,
    querySelector: () => null, querySelectorAll: () => []
  };
  const document = {
    title: 'Fixture - Chat',
    querySelectorAll(selector) {
      if (selector === '[role="dialog"],[role="alertdialog"]') return elements;
      if (selector === messageSelector) return dialogs.some(d => d.embedded) ? [group] : [];
      if (selector === '[role="textbox"][contenteditable="true"]') return codeText === null ? [] : [editor];
      return [];
    }
  };
  return vm.runInNewContext(source, {
    document, top: {}, location: {href: 'https://chat.google.com/app/chat/EXAMPLE'},
    Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, getComputedStyle: () => ({visibility: 'visible'}),
    innerWidth: 1440, innerHeight: 1000
  });
}

function attachmentProbe({zeroBody = false, attachments = []} = {}) {
  const dialog = {getAttribute: name => name === 'aria-hidden' ? 'true' : 'dialog', closest: () => null,
    getClientRects: () => [{}], getBoundingClientRect: () => ({left: -400, top: -400, right: -300, bottom: -300})};
  const group = {getAttribute: name => ({'data-id': 'message-1', 'data-user-id': 'sender-1'}[name] ?? null),
    closest: () => null, querySelector: () => null,
    querySelectorAll: selector => selector === '[jsname="bgckF"]' ? (zeroBody ? [] : [{childNodes: [], querySelector: () => null, querySelectorAll: () => []}]) : selector === '[data-attachment-name]' ? attachments : []};
  const input = {isConnected: true, ownerDocument: null};
  const document = {title: 'Fixture', querySelectorAll: selector => {
    if (selector === '[role="dialog"],[role="alertdialog"]') return [dialog];
    if (selector === messageSelector) return [group];
    if (selector === 'input[type="file"]') return [input];
    if (selector === '[data-composer-attachment]') return attachments;
    return [];
  }};
  input.ownerDocument = document;
  document.defaultView = {};
  document.defaultView.top = document.defaultView;
  return vm.runInNewContext(source, {document, top: document.defaultView, location: {href: 'https://example.test'}, innerWidth: 800, innerHeight: 600,
    Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, getComputedStyle: () => ({visibility: 'visible'})});
}
const specialMode = process.argv.includes('--composer-boundary') || process.argv.includes('--attachment-cases') || process.argv.includes('--boundary-states') || process.argv.includes('--outside-card') || process.argv.includes('--unsupported-label') || process.argv.includes('--sibling-remove') || process.argv.includes('--wrapped-card') || process.argv.includes('--card-association') || process.argv.includes('--bounded-card') || process.argv.includes('--root-metamorphic') || process.argv.includes('--r14-findings') || process.argv.includes('--r15-findings') || process.argv.includes('--r16-findings') || process.argv.includes('--r17-findings') || process.argv.includes('--diagnostic-card') || process.argv.includes('--diagnostic-predicates') || process.argv.includes('--grounded-cases') || process.argv.includes('--grounded-integration');
if (!specialMode) {
const offscreen = attachmentProbe({zeroBody: true, attachments: [{
  getAttribute: name => ({'data-attachment-name': 'note.md', 'data-attachment-pending': 'false', 'data-attachment-error': 'false'}[name] ?? null),
  querySelectorAll: () => []
}]});
assert.equal(offscreen.dialogs, 0, 'An entirely off-screen aria-hidden dialog does not block');
assert.equal(offscreen.publication_supported, false, 'Attachment-only history cannot satisfy publication support by itself');
assert.equal(attachmentProbe({zeroBody: true}).messages[0].body_count <= 1, true);
assert.equal(attachmentProbe().file_input_count, 1);
if (process.argv.includes('--composer-boundary') || process.argv.includes('--attachment-cases')) {
  // Special JSON modes are emitted before the ordinary assertion script below.
}
assert.equal(probe([{embedded: true}]).dialogs, 0, 'Historical nonmodal file card is embedded content');
assert.equal(probe([{embedded: true, modal: 'false'}]).dialogs, 0);
assert.equal(probe([{embedded: true, modal: 'true'}]).dialogs, 1, 'A modal still blocks inside history');
assert.equal(probe([{embedded: true, role: 'alertdialog'}]).dialogs, 1, 'An alert still blocks inside history');
assert.equal(probe([{}]).dialogs, 1, 'A nonmodal dialog outside a message still blocks');
assert.equal(probe([{role: 'alertdialog'}]).dialogs, 1);
assert.equal(probe([{embedded: true}, {modal: 'true'}]).dialogs, 1, 'Embedded content never hides a real overlay');
assert.equal(probe([{modal: 'true', hidden: true}]).dialogs, 0);
const literalCode = 'text\nACTUAL CODE\n  keep whitespace  ';
assert.equal(probe([], literalCode).editors[0].blocks[0].text, literalCode, 'The reader must retain all actual code, including a language-like first line');
}
const jsonMode = process.argv.includes('--signature-bodies') || process.argv.includes('--publication-bodies') || process.argv.includes('--composer-boundary') || process.argv.includes('--attachment-cases') || process.argv.includes('--boundary-states') || process.argv.includes('--outside-card') || process.argv.includes('--unsupported-label') || process.argv.includes('--sibling-remove') || process.argv.includes('--wrapped-card') || process.argv.includes('--card-association') || process.argv.includes('--bounded-card') || process.argv.includes('--root-metamorphic') || process.argv.includes('--r14-findings') || process.argv.includes('--r15-findings') || process.argv.includes('--r16-findings') || process.argv.includes('--r17-findings') || process.argv.includes('--diagnostic-card') || process.argv.includes('--diagnostic-predicates');
if (!specialMode) {
function focusProbe({code = false, collapsed = true, offset = 18, focus = 'send', count = 1} = {}) {
  const anchor = {nodeType: 3, nodeValue: '\u200b- sent by Fulcrum', parentElement: {closest: () => code ? {} : null}};
  const editor = {childNodes: [], getClientRects: () => [{}], getAttribute: () => null,
    querySelectorAll: () => [], querySelector: () => null, contains: node => node === anchor};
  const send = {getClientRects: () => [{}], getAttribute: name => name === 'aria-label' ? 'Send message' : null};
  const document = {title: 'Fixture - Chat', activeElement: focus === 'send' ? send : focus === 'editor' ? editor : null,
    getSelection: () => ({anchorNode: anchor, anchorOffset: offset, isCollapsed: collapsed}),
    querySelectorAll: selector => selector === '[role="textbox"][contenteditable="true"]' ? [editor] :
      selector === 'button,[role="button"]' ? Array(count).fill(send) : []};
  return vm.runInNewContext(source, {document, top: {}, location: {href: 'https://example.com'}, innerWidth: 1440, innerHeight: 1000,
    Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, getComputedStyle: () => ({visibility: 'visible'})});
}
assert.equal(focusProbe().send_focused, true);
assert.equal(focusProbe({focus: 'editor'}).editor_focused, true);
assert.equal(focusProbe({focus: 'other'}).send_focused, false);
assert.equal(focusProbe({count: 2}).send_focused, false);
assert.equal(focusProbe().caret_at_plain_end, true);
assert.equal(focusProbe({code: true}).caret_at_plain_end, false);
assert.equal(focusProbe({collapsed: false}).caret_at_plain_end, false);
assert.equal(focusProbe({offset: 0}).caret_at_plain_end, false);
}
if (process.argv.includes('--composer-boundary') || process.argv.includes('--attachment-cases')) {
function attachmentCase({name, label = null, busy = false, alert = false, sibling = false, removable = true} = {}) {
  const nodes = [];
  const element = attributes => { const node = {attributes, childNodes: [], getAttribute: key => attributes[key] ?? null, getClientRects: () => [{}], getBoundingClientRect: () => ({left: 10, top: 10, right: 20, bottom: 20}), matches: selector => selector === 'button,[role="button"]' ? attributes.role === 'button' : selector.split(',').some(part => part === '[role="progressbar"]' && attributes.role === 'progressbar' || part === '[role="alert"]' && attributes.role === 'alert' || part === '[aria-busy="true"]' && attributes['aria-busy'] === 'true'), closest: () => null, querySelector: () => null, querySelectorAll(selector) { return nodes.filter(item => (item.parentElement === node || item.parentElement === node.parentElement) && item.matches(selector)); }, parentElement: null}; nodes.push(node); return node; };
  const card = element({'data-attachment-card': 'true'});
  const chip = element({title: name, 'aria-label': label || `${name}, .`, 'aria-busy': busy ? 'true' : null, role: alert ? 'alert' : null});
  const wrapper = element({});
  chip.parentElement = wrapper; wrapper.parentElement = card;
  chip.closest = selector => selector === '[data-attachment-card]' ? card : null;
  element({role: 'button', 'aria-label': `Remove ${name}`}).parentElement = wrapper;
  card.querySelectorAll = selector => nodes.filter(item => item !== card && (item === chip || item.attributes.role === 'button' || item.attributes.role === 'progressbar' || item.attributes.role === 'alert' || item.attributes['aria-busy'] === 'true') && (item === chip || item.parentElement === card || item.parentElement === wrapper) && item.matches(selector));
  if (sibling) { const marker = element({role: 'progressbar'}); marker.parentElement = card; }

  const file = {isConnected: true, ownerDocument: null};
  const region = {contains: item => item === chip || item === file, querySelectorAll: selector => selector === 'input[type="file"]' ? [file] : selector.includes('button') ? nodes.filter(item => item !== chip && item.parentElement === wrapper && item.attributes.role === 'button') : selector.includes('[title]') ? [chip] : []};
  const document = {title: 'Fixture', querySelectorAll: selector => selector === '[role="textbox"][contenteditable="true"]' ? [{parentElement: region, contains: () => false, getClientRects: () => [{}], getAttribute: () => 'History is on', childNodes: [], querySelector: () => null, querySelectorAll: () => []}] : selector === 'input[type="file"]' ? [file] : selector.includes('[title]') ? nodes.filter(item => item.attributes.title) : []};
  file.ownerDocument = document;
  return vm.runInNewContext(source, {document, top: {}, innerWidth: 100, innerHeight: 100, location: {href: 'https://example.test'}, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, getComputedStyle: () => ({visibility: 'visible'})}).composer_attachments?.[0];
}
function boundaryDocument({history = false, control = false, composer = []} = {}) {
  const nodes = [];
  const element = (attributes, parent = null) => { const node = {attributes, tagName: attributes.jsname === 'ua35De' || attributes.role === 'button' ? 'BUTTON' : 'DIV', parentElement: parent, childNodes: [], getAttribute: key => attributes[key] ?? null, getClientRects: () => [{}], getBoundingClientRect: () => ({left: 10, top: 10, right: 20, bottom: 20}), matches: selector => selector.includes('button') ? (node.tagName === 'BUTTON' || attributes.role === 'button') : selector.split(',').some(part => (part.includes('BThTkd') && attributes.jsname === 'BThTkd') || (part.includes('XPtOyb') && attributes.jsname === 'XPtOyb') || (part.includes('ua35De') && attributes.jsname === 'ua35De') || part === '[role="progressbar"]' && attributes.role === 'progressbar' || part === '[role="alert"]' && attributes.role === 'alert' || part === '[aria-busy="true"]' && attributes['aria-busy'] === 'true'), contains(item) { for (let current = item; current; current = current.parentElement) if (current === node) return true; return false; }, closest(selector) { if ((selector === '[role="region"]' && attributes.role === 'region') || (selector.includes('data-id') && attributes.message) || (selector.includes('toolbar') && attributes.role === 'toolbar')) return node; return parent?.closest?.(selector) ?? null; }, querySelector: () => null, querySelectorAll(selector) { const descendants = []; const visit = current => { for (const item of nodes.filter(candidate => candidate.parentElement === current)) { descendants.push(item); visit(item); } }; visit(node); return descendants.filter(item => selector === 'input[type="file"]' ? item.attributes.type === 'file' : selector.includes('data-attachment-name') ? !!(item.attributes['data-attachment-name'] || (item.attributes.title && item.attributes['aria-label'])) : item.matches?.(selector)); }}; nodes.push(node); return node; };
  const historyGroup = element({message: true, role: 'group', 'data-id': 'old', 'data-user-id': 'sender-1'});
  if (history) element({'data-attachment-name': 'note.md', title: 'note.md'}, historyGroup);
  const page = element({});
  if (control) { const settings = element({title: 'Settings', 'aria-label': 'Settings'}, page); settings.tagName = 'BUTTON'; settings.matches = selector => !!selector && selector.includes('button') && !selector.includes('title'); }
  const region = element({role: 'region'}, page);
  const editor = element({role: 'textbox', 'aria-label': 'History is on', contenteditable: 'true'}, region);
  editor.childNodes = []; editor.querySelector = () => null;
  const file = element({type: 'file'}, region); file.isConnected = true; file.ownerDocument = null;
  for (const card of composer) {
    const shell = element({jsname: 'BThTkd'}, region);
    element({jsname: 'XPtOyb', title: card.title, 'aria-label': card['aria-label'], 'aria-busy': card['aria-busy'], role: card.role}, shell);
    const branch = element({}, shell);
    element({jsname: 'ua35De', jscontroller: 'PIVayb', role: 'button', 'aria-label': 'Remove ' + card.title}, branch);
  }
  const document = {title: 'Fixture', querySelectorAll(selector) { if (selector === messageSelector) return [historyGroup]; if (selector === '[role="textbox"][contenteditable="true"]') return [editor]; if (selector === 'input[type="file"]') return [file]; if (selector === '[jsname="bgckF"]') return []; if (selector.includes('button')) return nodes.filter(item => item.tagName === 'BUTTON'); if (selector.includes('[title]')) return nodes.filter(item => item.attributes.title); return nodes.filter(item => item.matches?.(selector) || (selector.includes('data-attachment-name') && item.attributes['data-attachment-name'])); }};
  file.ownerDocument = document; nodes.forEach(node => { node.ownerDocument = document; });
  return document;
}
if (process.argv.includes('--boundary-states')) {
  const make = ({nested = false, toolbar = false, foreign = false} = {}) => {
    const nodes = [];
    const element = (attributes, parent = null) => { const node = {attributes, parentElement: parent, childNodes: [], getAttribute: key => attributes[key] ?? null, getClientRects: () => [{}], contains: item => item === node || parentChain(item).includes(node), closest(selector) { return attributes['data-composer-boundary'] && selector === '[data-composer-boundary]' ? node : parent?.closest(selector) ?? null; }, matches: selector => selector.includes('toolbar') && attributes.role === 'toolbar', querySelectorAll(selector) { return nodes.filter(item => item !== node && parentChain(item).includes(node) && (selector.includes('title') ? !!(item.attributes.title && item.attributes['aria-label']) : false)); }}; nodes.push(node); return node; };
    const parentChain = item => { const chain = []; for (let node = item; node; node = node.parentElement) chain.push(node); return chain; };
    const boundary = element({'data-composer-boundary': 'true'});
    const inner = nested ? element({'data-composer-boundary': 'true'}, boundary) : boundary;
    const editor = element({role: 'textbox', 'aria-label': 'History is on'}, inner);
    if (toolbar) element({role: 'toolbar', title: 'Settings', 'aria-label': 'Settings'}, boundary);
    if (foreign) { const card = element({}, boundary); element({title: 'foreign.md', 'aria-label': 'foreign.md, .'}, card); element({role: 'button', 'aria-label': 'Remove foreign.md'}, card); }
    const document = {title: 'Fixture', querySelectorAll: selector => selector.includes('textbox') ? [editor] : []};
    return vm.runInNewContext(source, {document, top: {}, innerWidth: 100, innerHeight: 100, location: {href: 'https://example.test'}, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, getComputedStyle: () => ({visibility: 'visible'})});
  };
  process.stdout.write(JSON.stringify({missing: make(), nested: make({nested: true}), toolbar: make({toolbar: true}), foreign: make({foreign: true})}) + '\n');
  process.exit(0);
}
if (process.argv.includes('--composer-boundary')) {
  const run = document => vm.runInNewContext(source, {document, top: {}, innerWidth: 800, innerHeight: 600, location: {href: 'https://chat.google.com/app/chat/EXAMPLE'}, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, TextEncoder, getComputedStyle: () => ({visibility: 'visible'})});
  const publication = run(boundaryDocument({history: true, control: true}));
  const published = publication.messages.some(message => message.attachments === null) ? null : publication.messages.flatMap(message => message.attachments || []);
  publication.message_ids = ['before', 'after'];
  publication.messages = [{id: 'after', sender_id: 'sender-1', body_count: 1, local_only: 'false', pending: false, error: false, server: true, attachments: published, body: {blocks: [{type: 'text', text: 'Fixture secret hello'}, {type: 'code', text: 'pwd\nprintf \'%s\\n\' hello'}, {type: 'text', text: '- sent by Fulcrum'}], text: 'Fixture secret hello', forbidden: false, signature_list: false, signature_plain: true, mentions: []}}];
  publication.editors = [{name: 'History is on', text: '', blocks: [], forbidden: false, mentions: []}];
  const value = {boundary: publication.composer_boundary, composer_attachments: publication.composer_attachments, messages: publication.messages, message_ids: publication.message_ids, editors: publication.editors, controls: run(boundaryDocument({control: true})).composer_attachments, owned_composer: run(boundaryDocument({composer: [{title: 'note.md', 'aria-label': 'note.md, .'}]})).composer_attachments, foreign_composer: run(boundaryDocument({composer: [{title: 'foreign.md', 'aria-label': 'foreign.md, .'}]})).composer_attachments, pending_card: run(boundaryDocument({composer: [{title: 'note.md', 'aria-label': 'note.md, .', 'aria-busy': 'true'}]})).composer_attachments?.[0] || null, error_card: run(boundaryDocument({composer: [{title: 'note.md', 'aria-label': 'note.md, .', role: 'alert'}]})).composer_attachments?.[0] || null, unsupported_card: run(boundaryDocument({composer: [{title: 'note.md', 'aria-label': 'Something else'}]})).composer_attachments?.[0] || null};
  process.stdout.write(JSON.stringify(value) + '\n');
  process.exit(0);
}
  const attachmentCases = {comma: attachmentCase({name: 'note, draft.md'}), foreign: attachmentCase({name: 'note.md, foreign', removable: false}), rootBusy: attachmentCase({name: 'note.md', busy: true}), rootAlert: attachmentCase({name: 'note.md', alert: true}), siblingProgress: attachmentCase({name: 'note.md', sibling: true}), settled: attachmentCase({name: 'note.md'})};
  process.stdout.write(JSON.stringify(attachmentCases) + '\n');
  process.exit(0);
}
if (!jsonMode) process.stdout.write('8 focus probe assertions passed\n');
if (!jsonMode) process.stdout.write('9 DOM probe fixture assertions passed\n');

if (process.argv.includes('--diagnostic-predicates') || process.argv.includes('--diagnostic-card')) {
  const make = mutate => {
    const nodes = [];
    const element = (tag, attributes, parent = null) => { const node = {tagName: tag, attributes, parentElement: parent, childNodes: [], children: [], getAttribute: key => Object.hasOwn(attributes, key) ? attributes[key] : null, getClientRects: () => [{}], contains(item) { for (let current = item; current; current = current.parentElement) if (current === node) return true; return false; }, closest(selector) { for (let current = node; current; current = current.parentElement) if (current.matches?.(selector)) return current; return null; }, matches(selector) { return String(selector).split(',').some(part => { part = part.trim(); return part === '*' || (part === '[role="textbox"][contenteditable="true"]' && attributes.role === 'textbox') || (part === 'input[type="file"]' && tag === 'INPUT') || ((part === 'button' || part === '[role="button"]') && (tag === 'BUTTON' || attributes.role === 'button')) || ((part === '[jsname="BThTkd"]' || part === 'div[jsname="BThTkd"]' && tag === 'DIV') && attributes.jsname === 'BThTkd') || (part === '[jsname="XPtOyb"]' && attributes.jsname === 'XPtOyb') || (part === '[jsname="ua35De"]' && attributes.jsname === 'ua35De') || (part === '[jsname="dq27Te"]' && attributes.jsname === 'dq27Te') || (part === '[aria-label="Settings"]' && attributes['aria-label'] === 'Settings') || (part === '[aria-label="Details"]' && attributes['aria-label'] === 'Details') || (part === '[title="Settings"]' && attributes.title === 'Settings') || (part === '[title="Details"]' && attributes.title === 'Details') || (part === '[jscontroller="nqzCif"]' && attributes.jscontroller === 'nqzCif') || (part === '[title]' && attributes.title != null) || (part.includes('data-attachment') && Object.keys(attributes).some(key => key.startsWith('data-attachment'))) || (part.includes('aria-busy') && Object.hasOwn(attributes, 'aria-busy')) || (part.includes('progressbar') && attributes.role === 'progressbar') || (part.includes('alert') && String(attributes.role || '').includes('alert')) || (part === '[role="group"][data-id][data-user-id][data-message-multiplat-item-id]' && attributes.role === 'group' && attributes['data-id'] && attributes['data-user-id'] && attributes['data-message-multiplat-item-id']); }); }, querySelector(selector) { return node.querySelectorAll(selector)[0] || null; }, querySelectorAll(selector) { return nodes.filter(item => item !== node && node.contains(item) && item.matches(selector)); }}; if (parent) parent.children.push(node); nodes.push(node); return node; };
    const page = element('DIV', {}); const editor = element('DIV', {role: 'textbox', contenteditable: 'true', 'aria-label': 'History is on'}, page); const file = element('INPUT', {type: 'file'}, page); file.isConnected = true;
    const card = element('DIV', {jsname: 'BThTkd'}, page); const filename = element('DIV', {jsname: 'XPtOyb', title: 'T015-live-preview.md', 'aria-label': 'T015-live-preview.md, .'}, card); const branch = element('DIV', {}, card); const remove = element('BUTTON', {jsname: 'ua35De', 'aria-label': 'Remove T015-live-preview.md'}, branch);
    const view = {}; view.top = view; const document = {title: 'Fixture', defaultView: view, querySelectorAll: selector => nodes.filter(item => item.matches(selector))}; file.ownerDocument = document;
    const detach = node => { if (!node.parentElement) return; node.parentElement.children = node.parentElement.children.filter(item => item !== node); const index = nodes.indexOf(node); if (index >= 0) nodes.splice(index, 1); node.parentElement = null; };
    if (mutate) mutate({element, page, editor, file, card, filename, branch, remove, view, nodes, detach});
    const probed = vm.runInNewContext(source, {document, top: view.top, innerWidth: 800, innerHeight: 600, location: {href: 'https://example.test'}, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, TextEncoder, getComputedStyle: () => ({visibility: 'visible'})});
    return {boundary: probed.composer_boundary, attachments: probed.composer_attachments, preconditions_ok: probed.attachment_diagnostics.preconditions_ok, status: probed.attachment_diagnostics.status, cards: probed.attachment_diagnostics.cards, anomalies: probed.attachment_diagnostics.anomalies, file_input_count: probed.file_input_count};
  };
  const reparent = (node, parent) => { if (node.parentElement) node.parentElement.children = node.parentElement.children.filter(item => item !== node); parent.children.push(node); node.parentElement = parent; };
  if (!process.argv.includes('--diagnostic-predicates')) {
    const probed = make();
    process.stdout.write(JSON.stringify({composer_boundary: probed.boundary, composer_attachments: probed.attachments, attachment_diagnostics: {preconditions_ok: probed.preconditions_ok, status: probed.status, cards: probed.cards, anomalies: probed.anomalies, unmet_gates: ['G1_empty_and_controls', 'E1_upload_trial', 'E2_remove_trial', 'G4_other_labels', 'G5_published_inventory']}}) + '\n');
    process.exit(0);
  }
  const predicates = {
    positive: make(), nested_marker: make(({filename, element}) => element('DIV', {jsname: 'XPtOyb'}, filename)), extra_title: make(({card, element}) => element('SPAN', {title: 'foreign.pdf'}, card)),
    wrong_image: make(({card, element}) => element('IMG', {jscontroller: 'nqzCif', title: 'foreign.pdf'}, card)), ancestor_synthetic: make(({page}) => { page.attributes['data-attachment-name'] = 'foreign.pdf'; }),
    deep_remove: make(({card, element, remove}) => { let parent = card; for (let index = 0; index < 5; index += 1) parent = element('DIV', {}, parent); reparent(remove, parent); }),
    depth_four: make(({card, element, remove}) => { let parent = card; for (let index = 0; index < 3; index += 1) parent = element('DIV', {}, parent); reparent(remove, parent); }),
    depth_five: make(({card, element, remove}) => { let parent = card; for (let index = 0; index < 4; index += 1) parent = element('DIV', {}, parent); reparent(remove, parent); }),
    busy_ancestor: make(({page}) => { page.attributes['aria-busy'] = 'true'; }), orphan_synthetic: make(({page, element, card, filename, branch, remove, detach}) => { [card, filename, branch, remove].forEach(detach); element('SPAN', {'data-attachment-name': 'foreign.pdf'}, page); }),
    orphan_remove: make(({page, element, card, filename, branch, remove, detach}) => { [card, filename, branch, remove].forEach(detach); element('BUTTON', {'aria-label': 'Remove orphan.pdf'}, page); }),
    wrong_tag_card: make(({page, element, card, filename, branch, remove, detach}) => { [card, filename, branch, remove].forEach(detach); element('SPAN', {jsname: 'BThTkd', title: 'foreign.pdf'}, page); }),
    untitled_settings: make(({page, element, card, filename, branch, remove, detach}) => { [card, filename, branch, remove].forEach(detach); element('BUTTON', {jsname: 'dq27Te', 'aria-label': 'Settings'}, page); }),
    image_ua35: make(({filename, element}) => element('IMG', {jscontroller: 'nqzCif', jsname: 'ua35De', title: 'T015-live-preview.md'}, filename)),
    history_card: make(({page, element}) => { const root = element('DIV', {}); reparent(page, root); element('DIV', {jsname: 'BThTkd'}, element('DIV', {role: 'group', 'data-id': 'old', 'data-user-id': 'sender', 'data-message-multiplat-item-id': 'old'}, root)); }),
    busy_false: make(({page, element}) => element('DIV', {'aria-busy': 'false'}, page)), busy_empty: make(({page, element}) => element('DIV', {'aria-busy': ''}, page)),
    orphan_div_dq27: make(({page, element}) => element('DIV', {jsname: 'dq27Te'}, page)), orphan_div_settings: make(({page, element}) => element('DIV', {'aria-label': 'Settings'}, page)), orphan_div_details: make(({page, element}) => element('DIV', {'aria-label': 'Details'}, page)),
    card_settings: make(({card}) => { card.attributes['aria-label'] = 'Settings'; }), filename_settings: make(({filename}) => { filename.attributes['aria-label'] = 'Settings'; }), image_details: make(({filename, element}) => element('IMG', {jscontroller: 'nqzCif', title: 'Details'}, filename)),
    history_div_settings: make(({page, element}) => { const root = element('DIV', {}); reparent(page, root); element('DIV', {'aria-label': 'Settings'}, element('DIV', {role: 'group', 'data-id': 'old', 'data-user-id': 'sender', 'data-message-multiplat-item-id': 'old'}, root)); }),
    borrowed_remove: make(({page, element, card, remove}) => { const root = element('DIV', {}); reparent(page, root); const other = element('DIV', {jsname: 'BThTkd'}, page); element('DIV', {jsname: 'XPtOyb', title: 'other.md', 'aria-label': 'other.md, .'}, other); element('BUTTON', {jsname: 'ua35De', 'aria-label': 'Remove other.md'}, element('DIV', {}, other)); reparent(card, root); reparent(remove, element('DIV', {role: 'group', 'data-id': 'old', 'data-user-id': 'sender', 'data-message-multiplat-item-id': 'old'}, card)); }),
    borrowed_remove_alone: make(({page, element, card, remove}) => { const root = element('DIV', {}); reparent(page, root); reparent(card, root); reparent(remove, element('DIV', {role: 'group', 'data-id': 'old', 'data-user-id': 'sender', 'data-message-multiplat-item-id': 'old'}, card)); }),
    historical_nested_card: make(({page, element, card}) => { const root = element('DIV', {}); reparent(page, root); reparent(card, root); element('DIV', {jsname: 'BThTkd'}, element('DIV', {role: 'group', 'data-id': 'old', 'data-user-id': 'sender', 'data-message-multiplat-item-id': 'old'}, card)); }),
    live_nested_card: make(({element, card}) => element('DIV', {jsname: 'BThTkd'}, card)),
    wrong_editor: make(({editor}) => { editor.attributes['aria-label'] = 'Message'; }), framed_file: make(({file}) => { file.ownerDocument.defaultView = {top: {}}; })
  };
  process.stdout.write(JSON.stringify(predicates) + '\n');
  process.exit(0);
}
if (process.argv.includes('--grounded-integration') || process.argv.includes('--grounded-cases')) {
  const probeDom = mutate => {
    const nodes = [];
    const element = (tag, attributes, parent = null) => { const node = {tagName: tag, attributes, parentElement: parent, childNodes: [], children: [], innerText: '', getAttribute: key => Object.hasOwn(attributes, key) ? attributes[key] : null, getClientRects: () => [{}], contains(item) { for (let current = item; current; current = current.parentElement) if (current === node) return true; return false; }, closest(selector) { for (let current = node; current; current = current.parentElement) if (current.matches?.(selector)) return current; return null; }, querySelector: () => null, matches(selector) { return String(selector).split(',').some(part => { part = part.trim(); return part === '*' || (part === '[role="textbox"][contenteditable="true"]' && attributes.role === 'textbox') || (part === 'input[type="file"]' && tag === 'INPUT') || ((part === 'button' || part === '[role="button"]') && (tag === 'BUTTON' || attributes.role === 'button')) || (part === '[jsname="BThTkd"]' && attributes.jsname === 'BThTkd') || (part === '[jsname="XPtOyb"]' && attributes.jsname === 'XPtOyb') || (part === '[jsname="ua35De"]' && attributes.jsname === 'ua35De') || (part === '[jsname="sBlcJe"][data-chip-index]' && attributes.jsname === 'sBlcJe' && attributes['data-chip-index'] != null) || (part === '[jsname="sBlcJe"]' && attributes.jsname === 'sBlcJe') || (part === '[data-action="7"]' && attributes['data-action'] === '7') || (part === '[jscontroller="nqzCif"]' && attributes.jscontroller === 'nqzCif') || (part === '[title]' && attributes.title != null) || (part.includes('data-attachment') && Object.keys(attributes).some(key => key.startsWith('data-attachment'))) || (part.includes('aria-busy') && Object.hasOwn(attributes, 'aria-busy')) || (part.includes('progressbar') && attributes.role === 'progressbar') || (part.includes('alert') && String(attributes.role || '').includes('alert')) || (part === '[role="group"][data-id][data-user-id][data-message-multiplat-item-id]' && attributes.role === 'group' && attributes['data-id'] && attributes['data-user-id'] && attributes['data-message-multiplat-item-id']) || (part === '[jsname="bgckF"]' && attributes.jsname === 'bgckF'); }); }, querySelectorAll(selector) { return nodes.filter(item => item !== node && node.contains(item) && item.matches(selector)); }}; if (parent) parent.children.push(node); nodes.push(node); return node; };
    const page = element('DIV', {jsname: 'ZQsur'}); const shelf = element('DIV', {jsname: 'qaclne', jscontroller: 'WCjcW'}, page); const editor = element('DIV', {role: 'textbox', contenteditable: 'true', 'aria-label': 'History is on'}, page); const file = element('INPUT', {type: 'file', role: 'button', multiple: 'true'}, page); file.isConnected = true;
    const view = {}; view.top = view; const document = {title: 'Fixture - Chat', defaultView: view, querySelectorAll: selector => nodes.filter(item => item.matches(selector)), getSelection: () => null, activeElement: editor}; file.ownerDocument = document;
    const detach = node => { if (!node.parentElement) return; node.parentElement.children = node.parentElement.children.filter(item => item !== node); const index = nodes.indexOf(node); if (index >= 0) nodes.splice(index, 1); node.parentElement = null; };
    const addCard = ({name, aria, image = false, removeJs = 'PIVayb'} = {}) => { const card = element('DIV', {jsname: 'BThTkd'}, shelf); const filename = element('DIV', {jsname: 'XPtOyb', title: name, 'aria-label': aria}, card); const branch = element('DIV', {}, card); const remove = element('BUTTON', {jsname: 'ua35De', jscontroller: removeJs, 'aria-label': 'Remove ' + name}, branch); if (image) element('IMG', {jscontroller: 'nqzCif', title: name, alt: name}, filename); return {card, filename, branch, remove}; };
    const seed = {element, page, shelf, editor, file, view, nodes, detach, addCard};
    if (mutate) mutate(seed);
    return vm.runInNewContext(source, {document, top: view.top, innerWidth: 1200, innerHeight: 800, location: {href: 'https://chat.google.com/app/chat/EXAMPLE'}, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, TextEncoder, getComputedStyle: () => ({visibility: 'visible'})});
  };
  if (process.argv.includes('--grounded-cases')) {
    const cases = {
      md: probeDom(seed => seed.addCard({name: 'note.md', aria: 'note.md, .', removeJs: 'PIVayb'})),
      txt: probeDom(seed => seed.addCard({name: 'note.txt', aria: 'note.txt, .', removeJs: 'PIVayb'})),
      pdf: probeDom(seed => seed.addCard({name: 'doc.pdf', aria: 'doc.pdf, PDF.', removeJs: 'PIVayb'})),
      png: probeDom(seed => seed.addCard({name: 'image.png', aria: 'image.png, Image', image: true, removeJs: 'PIVayb'})),
      empty_toolbar: probeDom(seed => { seed.element('BUTTON', {role: 'button', title: 'Bold', 'aria-label': 'Bold'}, seed.page); seed.element('BUTTON', {role: 'button', title: 'Send message', 'aria-label': 'Send message'}, seed.page); }),
      orphan: probeDom(seed => {
        const outside = seed.element('DIV', {}, null);
        const card = seed.element('DIV', {jsname: 'BThTkd'}, outside);
        const filename = seed.element('DIV', {jsname: 'XPtOyb', title: 'foreign.md', 'aria-label': 'foreign.md, .'}, card);
        const branch = seed.element('DIV', {}, card);
        seed.element('BUTTON', {jsname: 'ua35De', jscontroller: 'PIVayb', 'aria-label': 'Remove foreign.md'}, branch);
      }),
      published_chip: probeDom(seed => { const group = seed.element('DIV', {role: 'group', 'data-id': 'message-1', 'data-user-id': 'sender-1', 'data-message-multiplat-item-id': '1'}, null); const chip = seed.element('DIV', {jsname: 'sBlcJe', 'data-chip-index': '0'}, group); seed.element('BUTTON', {role: 'button', 'data-action': '7', title: 'image.png', 'aria-label': 'Image, image.png.'}, chip); seed.element('BUTTON', {role: 'button', title: 'Send message', 'aria-label': 'Send message'}, seed.page); }),
      published_ungrounded: probeDom(seed => { const group = seed.element('DIV', {role: 'group', 'data-id': 'message-1', 'data-user-id': 'sender-1', 'data-message-multiplat-item-id': '1'}, null); const chip = seed.element('DIV', {jsname: 'sBlcJe', 'data-chip-index': '0'}, group); seed.element('BUTTON', {role: 'button', 'data-action': '7', title: 'image.png', 'aria-label': 'Wrong label.'}, chip); seed.element('BUTTON', {role: 'button', title: 'Send message', 'aria-label': 'Send message'}, seed.page); }),
      published_orphan_action: probeDom(seed => { const group = seed.element('DIV', {role: 'group', 'data-id': 'message-1', 'data-user-id': 'sender-1', 'data-message-multiplat-item-id': '1'}, null); seed.element('BUTTON', {role: 'button', 'data-action': '7', title: 'orphan.pdf', 'aria-label': 'PDF, orphan.pdf.'}, group); seed.element('BUTTON', {role: 'button', title: 'Send message', 'aria-label': 'Send message'}, seed.page); }),
      published_bare_sblcje: probeDom(seed => { const group = seed.element('DIV', {role: 'group', 'data-id': 'message-1', 'data-user-id': 'sender-1', 'data-message-multiplat-item-id': '1'}, null); seed.element('DIV', {jsname: 'sBlcJe'}, group); seed.element('BUTTON', {role: 'button', title: 'Send message', 'aria-label': 'Send message'}, seed.page); })
    };
    for (const [name, probed] of Object.entries(cases)) {
      assert.equal(probed.composer_boundary, name === 'orphan' ? 'unsupported' : 'supported', name);
      if (name === 'empty_toolbar') assert.equal(probed.composer_attachments?.length, 0);
      if (name === 'published_chip') assert.equal(JSON.stringify(probed.messages.at(-1)?.attachments), JSON.stringify([{name: 'image.png', pending: false, error: false}]));
      if (['published_ungrounded', 'published_orphan_action', 'published_bare_sblcje'].includes(name)) assert.equal(probed.messages.at(-1)?.attachments, null, name);
    }
    process.stdout.write(JSON.stringify(cases) + '\n');
    process.exit(0);
  }
  const textOnly = probeDom(seed => { seed.element('BUTTON', {role: 'button', title: 'Bold', 'aria-label': 'Bold'}, seed.page); seed.element('BUTTON', {role: 'button', title: 'Send message', 'aria-label': 'Send message'}, seed.page); });
  const attachmentMd = probeDom(seed => seed.addCard({name: 'note.md', aria: 'note.md, .', removeJs: 'PIVayb'}));
  const attachmentPdf = probeDom(seed => seed.addCard({name: 'doc.pdf', aria: 'doc.pdf, PDF.', removeJs: 'PIVayb'}));
  const cancelled = probeDom(seed => { seed.element('BUTTON', {role: 'button', title: 'Send message', 'aria-label': 'Send message'}, seed.page); });
  const publication = probeDom(seed => {
    const group = seed.element('DIV', {role: 'group', 'data-id': 'after', 'data-user-id': 'sender-1', 'data-message-multiplat-item-id': '1'}, seed.page);
    const body = seed.element('DIV', {jsname: 'bgckF'}, group);
    body.innerText = 'Fixture secret hello';
    const chip = seed.element('DIV', {jsname: 'sBlcJe', 'data-chip-index': '0'}, group);
    seed.element('BUTTON', {role: 'button', 'data-action': '7', title: 'note.md', 'aria-label': 'Text, note.md.'}, chip);
    seed.element('BUTTON', {role: 'button', title: 'Send message', 'aria-label': 'Send message'}, seed.page);
  });
  process.stdout.write(JSON.stringify({text_only: textOnly, attachment_md: attachmentMd, attachment_pdf: attachmentPdf, cancelled, publication_dom: publication}) + '\n');
  process.exit(0);
}
if (process.argv.includes('--r17-findings')) {
  const state = ({kind = 'equal', child = 'missing'} = {}) => {
    const nodes = [];
    const element = (attributes, parent = null, tag = 'div') => { const node = {tagName: tag.toUpperCase(), attributes, parentElement: parent, childNodes: [], getAttribute: key => Object.hasOwn(attributes, key) ? attributes[key] : null, getClientRects: () => [{}], getBoundingClientRect: () => ({left: 10, top: 10, right: 20, bottom: 20}), contains(item) { for (let current = item; current; current = current.parentElement) if (current === node) return true; return false; }, closest(selector) { if (Object.hasOwn(attributes, 'data-attachment-card') && selector === '[data-attachment-card]') return node; return parent?.closest?.(selector) ?? null; }, matches(selector) { return selector.split(',').some(part => (part === 'button' || part === '[role="button"]') && (tag === 'button' || attributes.role === 'button')); }, querySelector() { return null; }, querySelectorAll(selector) { return nodes.filter(item => item !== node && node.contains(item) && (selector.includes('button') ? item.matches(selector) : selector.includes('[title]') || selector.includes('data-attachment') ? item.attributes.title != null || item.getAttribute('data-attachment-name') != null || item.getAttribute('data-attachment-card') != null : false)); }}; nodes.push(node); return node; };
    const boundary = element({}); const editor = element({role: 'textbox', 'aria-label': 'History is on'}, boundary); const file = element({type: 'file'}, boundary); file.isConnected = true;
    if (kind === 'equal') { const card = element({}, boundary); element({title: 'foreign.md', 'aria-label': 'foreign.md'}, card, 'button'); element({role: 'button', 'aria-label': 'Remove foreign.md'}, card); }
    if (kind === 'ancestor') { const card = element({'data-attachment-card': '', title: 'owned.md'}, boundary); element({title: 'owned.md', 'aria-label': child === 'failed' ? 'Upload failed' : null}, card); element({role: 'button', 'aria-label': 'Remove owned.md'}, card); }
    if (kind === 'settings') element({title: 'Settings', 'aria-label': 'Settings'}, element({}, boundary), 'button');
    const document = {title: 'Fixture', querySelectorAll: selector => selector.includes('textbox') ? [editor] : selector === 'input[type="file"]' ? [file] : selector.includes('button') ? nodes.filter(item => item.tagName === 'BUTTON' || item.attributes.role === 'button') : selector.includes('[title]') || selector.includes('data-attachment') ? nodes.filter(item => item.attributes.title != null || item.getAttribute('data-attachment-card') != null) : []};
    file.ownerDocument = document;
    const probed = vm.runInNewContext(source, {document, top: {}, innerWidth: 100, innerHeight: 100, location: {href: 'https://example.test'}, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, getComputedStyle: () => ({visibility: 'visible'})});
    return {composer_boundary: probed.composer_boundary, composer_attachments: probed.composer_attachments};
  };
  process.stdout.write(JSON.stringify({equal_label: state(), failed_ancestor: state({kind: 'ancestor', child: 'failed'}), settings: state({kind: 'settings'})}) + '\n');
  process.exit(0);
}
if (process.argv.includes('--r16-findings')) {
  const state = ({name = 'README', label = null, marked = false, nested = false, conflict = false, pending = false} = {}) => {
    const nodes = [];
    const element = (attributes, parent = null, tag = 'div') => { const node = {tagName: tag.toUpperCase(), attributes, parentElement: parent, childNodes: [], getAttribute: key => Object.hasOwn(attributes, key) ? attributes[key] : null, getClientRects: () => [{}], getBoundingClientRect: () => ({left: 10, top: 10, right: 20, bottom: 20}), contains(item) { for (let current = item; current; current = current.parentElement) if (current === node) return true; return false; }, closest(selector) { if (Object.hasOwn(attributes, 'data-attachment-card') && selector === '[data-attachment-card]') return node; return parent?.closest?.(selector) ?? null; }, matches(selector) { return selector.split(',').some(part => (part === 'button' || part === '[role="button"]') && (tag === 'button' || attributes.role === 'button') || part === '[aria-busy="true"]' && attributes['aria-busy'] === 'true' || part === '[role="progressbar"]' && attributes.role === 'progressbar' || part === '[role="alert"]' && attributes.role === 'alert'); }, querySelector() { return null; }, querySelectorAll(selector) { return nodes.filter(item => item !== node && node.contains(item) && (selector.includes('button') ? item.matches(selector) : selector.includes('[title]') || selector.includes('data-attachment') ? item.attributes.title != null || item.getAttribute('data-attachment-name') != null || item.getAttribute('data-attachment-card') != null : item.matches(selector))); }}; nodes.push(node); return node; };
    const page = element({}); const boundary = element({}, page);
    const editor = element({role: 'textbox', 'aria-label': 'History is on'}, boundary); const file = element({type: 'file'}, boundary); file.isConnected = true;
    if (!marked && !nested && !conflict) { const card = element({'data-attachment-card': ''}, boundary); element({title: name, 'aria-label': label === undefined ? `${name}, .` : label}, card, 'button'); element({role: 'button', 'aria-label': `Remove ${name}`}, card); }
    if (conflict) { const card = element({'data-attachment-card': '', 'data-attachment-name': 'foreign.md'}, boundary); element({title: 'owned.md', 'aria-label': 'owned.md, .'}, card); element({role: 'button', 'aria-label': 'Remove owned.md'}, card); }
    if (pending) { const card = element({'data-attachment-card': '', 'data-attachment-name': 'owned.md', 'data-attachment-pending': 'true'}, boundary); element({title: 'owned.md', 'aria-label': 'owned.md, .'}, card); element({role: 'button', 'aria-label': 'Remove owned.md'}, card); }
    if (nested) { const outer = element({'data-attachment-card': '', 'aria-busy': 'true'}, boundary); const inner = element({'data-attachment-card': ''}, outer); element({title: 'owned.md', 'aria-label': 'owned.md, .'}, inner); element({role: 'button', 'aria-label': 'Remove owned.md'}, inner); }
    const document = {title: 'Fixture', querySelectorAll: selector => selector.includes('textbox') ? [editor] : selector === 'input[type="file"]' ? [file] : selector.includes('button') ? nodes.filter(item => item.tagName === 'BUTTON' || item.attributes.role === 'button') : selector.includes('[title]') || selector.includes('data-attachment') ? nodes.filter(item => item.attributes.title != null || item.getAttribute('data-attachment-name') != null || item.getAttribute('data-attachment-card') != null) : []};
    file.ownerDocument = document;
    const probed = vm.runInNewContext(source, {document, top: {}, innerWidth: 100, innerHeight: 100, location: {href: 'https://example.test'}, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, getComputedStyle: () => ({visibility: 'visible'})});
    return {composer_boundary: probed.composer_boundary, composer_attachments: probed.composer_attachments};
  };
  process.stdout.write(JSON.stringify({readme: state(), trailing: state({name: 'notes.'}), conflict: state({conflict: true}), pending: state({pending: true}), nested: state({nested: true})}) + '\n');
  process.exit(0);
}
if (process.argv.includes('--r15-findings')) {
  const state = ({toolbar = false, marker = 'busy', shared = false, grouped = false, empty = false, settings = false} = {}) => {
    const nodes = [];
    const element = (attributes, parent = null, tag = 'div') => { const node = {tagName: tag.toUpperCase(), attributes, parentElement: parent, childNodes: [], getAttribute: key => Object.hasOwn(attributes, key) ? attributes[key] : null, getClientRects: () => [{}], getBoundingClientRect: () => ({left: 10, top: 10, right: 20, bottom: 20}), contains(item) { for (let current = item; current; current = current.parentElement) if (current === node) return true; return false; }, closest(selector) { if (attributes.role === 'toolbar' && selector.includes('toolbar')) return node; if (Object.hasOwn(attributes, 'data-attachment-card') && selector === '[data-attachment-card]') return node; return parent?.closest?.(selector) ?? null; }, matches(selector) { return selector.split(',').some(part => (part === 'button' || part === '[role="button"]') && (tag === 'button' || attributes.role === 'button') || part === '[aria-busy="true"]' && attributes['aria-busy'] === 'true' || part === '[role="progressbar"]' && attributes.role === 'progressbar' || part === '[role="alert"]' && attributes.role === 'alert'); }, querySelector(selector) { return node.querySelectorAll(selector)[0] ?? null; }, querySelectorAll(selector) { return nodes.filter(item => item !== node && node.contains(item) && (selector.includes('textbox') || selector.includes('input') || selector.includes('toolbar') ? item.matches(selector) || (selector.includes('toolbar') && item.attributes.role === 'toolbar') || (selector.includes('input') && item.attributes.type === 'file') : selector.includes('button') ? item.matches(selector) : selector.includes('[title]') || selector.includes('data-attachment') ? item.attributes.title != null || item.getAttribute('data-attachment-name') != null || item.getAttribute('data-attachment-card') != null : item.matches(selector))); }}; nodes.push(node); return node; };
    const page = element({}); const boundary = element({}, page);
    const editor = element({role: 'textbox', 'aria-label': 'History is on'}, boundary); const file = element({type: 'file'}, boundary); file.isConnected = true;
    if (settings) element({title: 'Settings', 'aria-label': 'Settings'}, page, 'button');
    if (!empty && !settings) {
      const card = element({}, boundary);
      const wrapper = element({}, card);
      element({title: 'owned.md', 'aria-label': 'owned.md, .'}, wrapper);
      if (!shared) element({role: 'button', 'aria-label': 'Remove owned.md'}, wrapper);
      if (marker === 'busy') card.attributes['aria-busy'] = 'true';
      if (marker === 'progress') element({role: 'progressbar'}, card);
      if (marker === 'alert') element({role: 'alert'}, card);
      if (shared) element({role: 'button', 'aria-label': 'Remove owned.md'}, element({}, card));
      if (toolbar) element({role: 'toolbar'}, card);
    }
    if (grouped) { const marked = element({'data-attachment-card': ''}, boundary); element({title: 'owned.md', 'aria-label': 'owned.md, .'}, marked); element({role: 'button', 'aria-label': 'Remove owned.md'}, marked); element({title: 'foreign.md', 'aria-label': 'foreign.md, .'}, element({}, marked), 'button'); }
    if (empty) element({'data-attachment-card': '', role: 'button', title: ''}, boundary, 'button');
    const document = {title: 'Fixture', querySelectorAll: selector => selector.includes('textbox') ? [editor] : selector === 'input[type="file"]' ? [file] : selector.includes('button') ? nodes.filter(item => item.tagName === 'BUTTON' || item.attributes.role === 'button') : selector.includes('[title]') || selector.includes('data-attachment') ? nodes.filter(item => item.attributes.title != null || item.getAttribute('data-attachment-name') != null || item.getAttribute('data-attachment-card') != null) : []};
    file.ownerDocument = document;
    const probed = vm.runInNewContext(source, {document, top: {}, innerWidth: 100, innerHeight: 100, location: {href: 'https://example.test'}, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, getComputedStyle: () => ({visibility: 'visible'})});
    return {composer_boundary: probed.composer_boundary, composer_attachments: probed.composer_attachments};
  };
  process.stdout.write(JSON.stringify({busy: state(), busy_toolbar: state({toolbar: true}), progress_toolbar: state({marker: 'progress', toolbar: true}), shared: state({shared: true, marker: 'none'}), grouped: state({grouped: true, marker: 'none'}), empty_marked: state({empty: true, marker: 'none'}), settings: state({settings: true, marker: 'none'})}) + '\n');
  process.exit(0);
}
if (process.argv.includes('--r14-findings')) {
  const state = ({finding = 'state', details = false, label = null, control = 'sibling', placement = 'inside'} = {}) => {
    const nodes = [];
    const element = (attributes, parent = null, tag = 'div') => { const node = {tagName: tag.toUpperCase(), attributes, parentElement: parent, childNodes: [], getAttribute: key => Object.hasOwn(attributes, key) ? attributes[key] : null, getClientRects: () => [{}], getBoundingClientRect: () => ({left: 10, top: 10, right: 20, bottom: 20}), contains(item) { for (let current = item; current; current = current.parentElement) if (current === node) return true; return false; }, closest(selector) { return attributes.role === 'toolbar' && selector.includes('toolbar') ? node : attributes['data-attachment-card'] != null && selector === '[data-attachment-card]' ? node : parent?.closest?.(selector) ?? null; }, matches(selector) { return selector.split(',').some(part => (part === 'button' || part === '[role="button"]') && (tag === 'button' || attributes.role === 'button') || part === '[aria-busy="true"]' && attributes['aria-busy'] === 'true' || part === '[role="progressbar"]' && attributes.role === 'progressbar' || part === '[role="alert"]' && attributes.role === 'alert'); }, querySelector() { return null; }, querySelectorAll(selector) { return nodes.filter(item => item !== node && node.contains(item) && (selector.includes('button') ? item.matches(selector) : selector.includes('[title]') || selector.includes('data-attachment') ? item.attributes.title != null || item.attributes['data-attachment-name'] != null || item.attributes['data-attachment-card'] != null : item.matches(selector))); }}; nodes.push(node); return node; };
    const page = element({}); const boundary = element({}, page); const host = placement === 'outside' ? page : boundary;
    const editor = element({role: 'textbox', 'aria-label': 'History is on'}, boundary); editor.querySelectorAll = () => [];
    const file = element({type: 'file'}, boundary); file.isConnected = true;
    if (finding === 'state') { const card = element({}, host); const wrapper = element({}, card); element({title: 'owned.md', 'aria-label': 'owned.md, .'}, wrapper); element({role: 'button', 'aria-label': 'Remove owned.md'}, wrapper); card.attributes['aria-busy'] = 'true'; if (details) element({title: 'Details', 'aria-label': 'Details'}, card, 'button'); }
    if (finding === 'label') { const card = element({}, host); const chip = element({title: 'foreign.md', 'aria-label': label}, card, 'button'); if (control === 'sibling') element({role: 'button', 'aria-label': 'Remove foreign.md'}, card); if (control === 'mismatch') element({role: 'button', 'aria-label': 'Remove other.md'}, card); }
    if (finding === 'duplicate') { const card = element({'data-attachment-card': ''}, boundary); element({title: 'owned.md', 'aria-label': 'owned.md, .'}, card); element({role: 'button', 'aria-label': 'Remove owned.md'}, card); element({role: 'button', 'aria-label': 'Remove owned.md'}, element({role: 'toolbar'}, boundary), 'button'); }
    const document = {title: 'Fixture', querySelectorAll: selector => selector.includes('textbox') ? [editor] : selector === 'input[type="file"]' ? [file] : selector.includes('button') ? nodes.filter(item => item.tagName === 'BUTTON' || item.attributes.role === 'button') : selector.includes('[title]') || selector.includes('data-attachment') ? nodes.filter(item => item.attributes.title != null || item.attributes['data-attachment-name'] != null || item.attributes['data-attachment-card'] != null) : []};
    file.ownerDocument = document;
    const probed = vm.runInNewContext(source, {document, top: {}, innerWidth: 100, innerHeight: 100, location: {href: 'https://example.test'}, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, getComputedStyle: () => ({visibility: 'visible'})});
    return {composer_boundary: probed.composer_boundary, composer_attachments: probed.composer_attachments};
  };
  process.stdout.write(JSON.stringify({state: state(), state_details: state({details: true}), label_missing: state({finding: 'label', label: null}), label_failed: state({finding: 'label', label: 'Upload failed'}), duplicate: state({finding: 'duplicate'})}) + '\n');
  process.exit(0);
}
if (process.argv.includes('--root-metamorphic')) {
  const state = ({extra = false, marker = null, buttonFile = false, remove = 'toolbar'} = {}) => {
    const nodes = [];
    const element = (attributes, parent = null, tag = 'div') => { const node = {tagName: tag.toUpperCase(), attributes, parentElement: parent, childNodes: [], getAttribute: key => attributes[key] ?? null, getClientRects: () => [{}], getBoundingClientRect: () => ({left: 10, top: 10, right: 20, bottom: 20}), contains(item) { for (let current = item; current; current = current.parentElement) if (current === node) return true; return false; }, closest(selector) { return attributes.role === 'toolbar' && selector.includes('toolbar') ? node : parent?.closest?.(selector) ?? null; }, matches(selector) { return selector.split(',').some(part => (part === 'button' || part === '[role="button"]') && (tag === 'button' || attributes.role === 'button') || part === '[aria-busy="true"]' && attributes['aria-busy'] === 'true' || part === '[role="progressbar"]' && attributes.role === 'progressbar' || part === '[role="alert"]' && attributes.role === 'alert'); }, querySelector() { return null; }, querySelectorAll(selector) { return nodes.filter(item => item !== node && node.contains(item) && (selector.includes('button') ? item.matches(selector) : selector.includes('[title]') || selector.includes('data-attachment') ? item.attributes.title != null || item.attributes['data-attachment-name'] != null : item.matches(selector) || item.attributes['aria-busy'] === 'true' || item.attributes.role === 'progressbar' || item.attributes.role === 'alert')); }}; nodes.push(node); return node; };
    const page = element({}); const boundary = element({}, page);
    const editor = element({role: 'textbox', 'aria-label': 'History is on'}, boundary); editor.querySelectorAll = () => [];
    const file = element({type: 'file'}, boundary); file.isConnected = true;
    const card = element({}, boundary); const wrapper = element({}, card);
    const chip = buttonFile ? element({title: 'foreign.md', 'aria-label': 'foreign.md, .'}, wrapper, 'button') : element({title: 'owned.md', 'aria-label': 'owned.md, .'}, wrapper);
    if (marker === 'busy') card.attributes['aria-busy'] = 'true';
    if (marker === 'progress') element({role: 'progressbar'}, card);
    if (marker === 'alert') element({role: 'alert'}, card);
    if (remove === 'card') element({role: 'button', 'aria-label': `Remove ${chip.attributes.title}`}, card);
    if (remove === 'toolbar') element({tagName: 'BUTTON', 'aria-label': `Remove ${chip.attributes.title}`}, element({role: 'toolbar'}, boundary), 'button');
    if (remove === 'mismatch') element({role: 'button', 'aria-label': 'Remove someone-else.md'}, card);
    if (extra) element({title: 'Formatting', 'aria-label': 'Formatting'}, element({role: 'toolbar'}, boundary), 'button');
    if (marker) element({title: 'Details', 'aria-label': 'Details'}, card, 'button');
    const document = {title: 'Fixture', querySelectorAll: selector => selector.includes('textbox') ? [editor] : selector === 'input[type="file"]' ? [file] : selector.includes('button') ? nodes.filter(item => item.tagName === 'BUTTON' || item.attributes.role === 'button') : selector.includes('[title]') || selector.includes('data-attachment') ? nodes.filter(item => item.attributes.title != null || item.attributes['data-attachment-name'] != null) : []};
    file.ownerDocument = document;
    boundary.querySelectorAll = selector => nodes.filter(item => boundary.contains(item) && (selector.includes('button') ? item.tagName === 'BUTTON' || item.attributes.role === 'button' : selector.includes('[title]') ? item.attributes.title != null : selector.includes('aria-busy') || selector.includes('progressbar') || selector.includes('alert') ? item.attributes['aria-busy'] === 'true' || item.attributes.role === 'progressbar' || item.attributes.role === 'alert' : false));
    const probed = vm.runInNewContext(source, {document, top: {}, innerWidth: 100, innerHeight: 100, location: {href: 'https://example.test'}, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, getComputedStyle: () => ({visibility: 'visible'})});
    return {composer_boundary: probed.composer_boundary, composer_attachments: probed.composer_attachments};
  };
  process.stdout.write(JSON.stringify({lone: state(), extra: state({extra: true}), busy: state({marker: 'busy', remove: 'card'}), busy_details: state({marker: 'busy', remove: 'card'}), button_wrapped: state({buttonFile: true, remove: 'card'}), button_absent: state({buttonFile: true, remove: 'none'}), button_mismatch: state({buttonFile: true, remove: 'mismatch'})}) + '\n');
  process.exit(0);
}
if (process.argv.includes('--bounded-card')) {
  const state = ({shape = 'toolbar'} = {}) => {
    const nodes = [];
    const element = (attributes, parent = null, tag = 'div') => { const node = {tagName: tag.toUpperCase(), attributes, parentElement: parent, childNodes: [], getAttribute: key => attributes[key] ?? null, getClientRects: () => [{}], contains(item) { for (let current = item; current; current = current.parentElement) if (current === node) return true; return false; }, closest(selector) { if (attributes.role === 'toolbar' && selector.includes('toolbar')) return node; if (attributes['data-attachment-card'] && selector === '[data-attachment-card]') return node; return parent?.closest?.(selector) ?? null; }, matches(selector) { return selector.split(',').some(part => (part === 'button' || part === '[role="button"]') && (attributes.role === 'button' || tag === 'button') || part === '[aria-busy="true"]' && attributes['aria-busy'] === 'true'); }, querySelector() { return null; }, querySelectorAll(selector) { return nodes.filter(item => item !== node && node.contains(item) && (selector.includes('button') ? item.matches(selector) : selector.includes('[title]') || selector.includes('data-attachment') ? item.attributes.title != null || item.attributes['data-attachment-name'] != null || item.attributes['data-attachment-card'] != null : item.matches(selector))); }}; nodes.push(node); return node; };
    const page = element({}); const boundary = element({}, page);
    const editor = element({role: 'textbox', 'aria-label': 'History is on'}, boundary); editor.querySelectorAll = () => [];
    const file = element({type: 'file'}, boundary); file.isConnected = true;
    if (shape !== 'native-empty') { const card = element({}, boundary); element({title: 'owned.md', 'aria-label': shape === 'plain' ? 'owned.md, .' : 'owned.md, .'}, card); if (shape !== 'plain' && shape !== 'button-file') element({role: 'button', 'aria-label': 'Remove owned.md'}, card); if (shape === 'button-file') { const fileCard = element({role: 'button', title: 'foreign.md', 'aria-label': 'foreign.md, .'}, boundary); element({role: 'button', 'aria-label': 'Remove foreign.md'}, fileCard.parentElement); } }
    if (shape === 'toolbar') element({role: 'button', 'aria-label': 'Remove owned.md'}, element({role: 'toolbar'}, boundary));
    if (shape === 'empty-name') element({'data-attachment-name': '', title: 'owned.md', 'aria-label': 'Uploading'}, boundary);
    if (shape === 'native') element({}, page, 'button').attributes = {title: 'Settings', 'aria-label': 'Settings'};
    if (shape === 'native-empty') element({}, page, 'button').attributes = {title: 'Settings', 'aria-label': 'Settings'};
    const document = {title: 'Fixture', querySelectorAll: selector => selector.includes('textbox') ? [editor] : selector === 'input[type="file"]' ? [file] : selector.includes('button') ? nodes.filter(item => item.tagName === 'BUTTON' || item.attributes.role === 'button') : selector.includes('[title]') || selector.includes('data-attachment') ? nodes.filter(item => item.attributes.title != null || item.attributes['data-attachment-name'] != null || item.attributes['data-attachment-card'] != null) : []};
    file.ownerDocument = document;
    const probed = vm.runInNewContext(source, {document, top: {}, innerWidth: 100, innerHeight: 100, location: {href: 'https://example.test'}, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, getComputedStyle: () => ({visibility: 'visible'})});
    return {composer_boundary: probed.composer_boundary, composer_attachments: probed.composer_attachments};
  };
  process.stdout.write(JSON.stringify({toolbar: state(), plain: state({shape: 'plain'}), button_file: state({shape: 'button-file'}), empty_name: state({shape: 'empty-name'}), native: state({shape: 'native'}), native_empty: state({shape: 'native-empty'})}) + '\n');
  process.exit(0);
}
if (process.argv.includes('--card-association')) {
  const state = ({marker = 'busy-root', toolbar = false, unknown = false, ordinary = false, outside = false} = {}) => {
    const nodes = [];
    const element = (attributes, parent = null) => { const node = {attributes, parentElement: parent, childNodes: [], getAttribute: key => attributes[key] ?? null, getClientRects: () => [{}], contains(item) { for (let current = item; current; current = current.parentElement) if (current === node) return true; return false; }, closest(selector) { if (attributes.role === 'toolbar' && selector.includes('toolbar')) return node; if (attributes['data-attachment-card'] && selector === '[data-attachment-card]') return node; return parent?.closest?.(selector) ?? null; }, matches(selector) { return selector.split(',').some(part => part === 'button' && attributes.role === 'button' || part === '[role="button"]' && attributes.role === 'button' || part === '[aria-busy="true"]' && attributes['aria-busy'] === 'true' || part === '[role="progressbar"]' && attributes.role === 'progressbar' || part === '[role="alert"]' && attributes.role === 'alert'); }, querySelector() { return null; }, querySelectorAll(selector) { return nodes.filter(item => item !== node && node.contains(item) && (selector === 'input[type="file"]' ? item.attributes.type === 'file' : selector.includes('button') ? item.matches(selector) : selector.includes('[title]') || selector.includes('data-attachment') ? !!(item.attributes.title || item.attributes['data-attachment-name'] || item.attributes['data-attachment-card']) : selector.includes('aria-busy') || selector.includes('progressbar') || selector.includes('alert') ? item.attributes['aria-busy'] === 'true' || item.attributes.role === 'progressbar' || item.attributes.role === 'alert' || item.matches(selector) : item.matches(selector))); }}; nodes.push(node); return node; };
    const page = element({}); const boundary = element({}, page); const host = outside ? page : boundary;
    page.contains = item => { for (let current = item; current && current !== page.parentElement; current = current.parentElement) if (current === page) return true; return false; };
    const editor = element({role: 'textbox', 'aria-label': 'History is on'}, boundary); editor.querySelectorAll = () => [];
    const file = element({type: 'file'}, boundary); file.isConnected = true;
    const card = ordinary ? null : element({}, host); const wrapper = card ? element({}, card) : null;
    const chip = card ? element({title: 'owned.md', 'aria-label': 'owned.md, .'}, wrapper) : null;
    if (card) element({role: 'button', 'aria-label': 'Remove owned.md'}, wrapper);
    if (card && marker === 'busy-root') card.attributes['aria-busy'] = 'true';
    if (card && marker === 'progress') element({role: 'progressbar'}, card);
    if (card && marker === 'alert') element({role: 'alert'}, card);
    if (toolbar) element({role: 'button', 'aria-label': 'Remove owned.md'}, element({role: 'toolbar'}, boundary));
    if (unknown) element({'data-attachment-card': 'true', 'aria-busy': 'true'}, outside ? page : boundary);
    if (ordinary) element({role: 'button', title: 'Settings', 'aria-label': 'Settings'}, page);
    const document = {title: 'Fixture', querySelectorAll: selector => selector.includes('textbox') ? [editor] : selector === 'input[type="file"]' ? [file] : selector.includes('button') ? nodes.filter(item => item.attributes.role === 'button') : selector.includes('[title]') || selector.includes('data-attachment') ? nodes.filter(item => item.attributes.title || item.attributes['data-attachment-name'] || item.attributes['data-attachment-card']) : []};
    file.ownerDocument = document;
    const probed = vm.runInNewContext(source, {document, top: {}, innerWidth: 100, innerHeight: 100, location: {href: 'https://example.test'}, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, getComputedStyle: () => ({visibility: 'visible'})});
    return {composer_boundary: probed.composer_boundary, composer_attachments: probed.composer_attachments, editors: probed.editors, filename: chip?.getAttribute('title') || null};
  };
  process.stdout.write(JSON.stringify({busy_root: state(), sibling_progress: state({marker: 'progress'}), sibling_alert: state({marker: 'alert'}), toolbar_remove: state({toolbar: true}), unknown_inside: state({unknown: true}), unknown_outside: state({unknown: true, outside: true}), ordinary_settings: state({ordinary: true, marker: 'none'})}) + '\n');
  process.exit(0);
}
if (process.argv.includes('--wrapped-card')) {
  const state = ({outside = false, filenameWrap = false, controlWrap = false, marked = false, remove = 'exact', pending = false, error = false, owned = false} = {}) => {
    const nodes = [];
    const element = (attributes, parent = null) => { const node = {attributes, parentElement: parent, childNodes: [], getAttribute: key => attributes[key] ?? null, getClientRects: () => [{}], contains(item) { for (let current = item; current; current = current.parentElement) if (current === node) return true; return false; }, closest(selector) { return attributes['data-attachment-card'] && selector === '[data-attachment-card]' ? node : parent?.closest?.(selector) ?? null; }, matches(selector) { return selector.split(',').some(part => part === 'button' && attributes.role === 'button' || part === '[role="button"]' && attributes.role === 'button' || part === '[aria-busy="true"]' && attributes['aria-busy'] === 'true' || part === '[role="progressbar"]' && attributes.role === 'progressbar' || part === '[role="alert"]' && attributes.role === 'alert'); }, querySelector: () => null, querySelectorAll(selector) { return nodes.filter(item => item !== node && node.contains(item) && (selector === 'input[type="file"]' ? item.attributes.type === 'file' : selector.includes('button') ? item.matches(selector) : selector.includes('[title]') || selector.includes('data-attachment') ? !!(item.attributes.title || item.attributes['data-attachment-name'] || item.attributes['data-attachment-card']) : item.matches(selector))); }}; nodes.push(node); return node; };
    const outer = element({}); const inner = element({}, outer); const host = outside ? outer : inner;
    const editor = element({role: 'textbox', 'aria-label': 'History is on'}, inner); editor.querySelectorAll = () => [];
    const file = element({type: 'file'}, inner); file.isConnected = true;
    const card = element(marked ? {'data-attachment-card': 'true'} : {}, host);
    const filenameHost = filenameWrap ? element({}, card) : card;
    const controlHost = controlWrap ? element({}, card) : card;
    const chip = element({title: 'foreign.md', 'aria-label': pending ? 'foreign.md, Uploading' : error ? 'foreign.md, Upload failed' : 'foreign.md, .', 'aria-busy': pending ? 'true' : null, role: error ? 'alert' : null}, filenameHost);
    const labels = {exact: 'Remove foreign.md', case: 'Remove Foreign.md', substring: 'Remove foreign', absent: 'Remove attachment', ambiguous: 'Remove foreign.md'};
    if (labels[remove]) element({role: 'button', 'aria-label': labels[remove]}, controlHost === host ? card : controlHost);
    if (remove === 'ambiguous') element({role: 'button', 'aria-label': labels[remove]}, controlHost === host ? card : controlHost);
    if (owned) { const ownedCard = element({}, inner); element({title: 'owned.md', 'aria-label': 'owned.md, .'}, ownedCard); element({role: 'button', 'aria-label': 'Remove owned.md'}, ownedCard); }
    const document = {title: 'Fixture', querySelectorAll: selector => selector.includes('textbox') ? [editor] : selector === 'input[type="file"]' ? [file] : selector.includes('button') ? nodes.filter(item => item.attributes.role === 'button') : selector.includes('[title]') || selector.includes('data-attachment-card') ? nodes.filter(item => item.attributes.title || item.attributes['data-attachment-card']) : []};
    file.ownerDocument = document;
    const probed = vm.runInNewContext(source, {document, top: {}, innerWidth: 100, innerHeight: 100, location: {href: 'https://example.test'}, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, getComputedStyle: () => ({visibility: 'visible'})});
    return {composer_boundary: probed.composer_boundary, composer_attachments: probed.composer_attachments, filename: chip.getAttribute('title')};
  };
  const cases = {};
  for (const placement of ['inside', 'outside', 'mixed']) for (const wrap of ['filename', 'control', 'both']) for (const marked of [false, true]) for (const remove of ['exact', 'absent', 'case', 'substring', 'ambiguous']) for (const stateName of ['plain', 'pending', 'error']) {
    cases[`${placement}-${wrap}-${marked ? 'marked' : 'unmarked'}-${remove}-${stateName}`] = state({outside: placement !== 'inside', owned: placement === 'mixed', filenameWrap: wrap !== 'control', controlWrap: wrap !== 'filename', marked, remove, pending: stateName === 'pending', error: stateName === 'error'});
  }
  process.stdout.write(JSON.stringify(cases) + '\n');
  process.exit(0);
}
if (process.argv.includes('--sibling-remove') || process.argv.includes('--unsupported-label') || process.argv.includes('--outside-card')) {
  const probeLive = mutate => {
    const nodes = [];
    const element = (attributes, parent = null) => { const node = {attributes, tagName: attributes.jsname === 'ua35De' || attributes.role === 'button' ? 'BUTTON' : 'DIV', parentElement: parent, childNodes: [], getAttribute: key => attributes[key] ?? null, getClientRects: () => [{}], getBoundingClientRect: () => ({left: 10, top: 10, right: 20, bottom: 20}), contains(item) { for (let current = item; current; current = current.parentElement) if (current === node) return true; return false; }, closest: () => null, querySelector: () => null, matches(selector) { return String(selector).split(',').some(part => { part = part.trim(); return (part.includes('BThTkd') && attributes.jsname === 'BThTkd') || (part.includes('XPtOyb') && attributes.jsname === 'XPtOyb') || (part.includes('ua35De') && attributes.jsname === 'ua35De') || (part.includes('textbox') && attributes.role === 'textbox') || (part === 'input[type="file"]' && attributes.type === 'file') || ((part === 'button' || part === '[role="button"]') && (node.tagName === 'BUTTON' || attributes.role === 'button')) || (part.includes('aria-busy') && attributes['aria-busy'] === 'true') || (part.includes('progressbar') && attributes.role === 'progressbar') || (part.includes('alert') && attributes.role === 'alert'); }); }, querySelectorAll(selector) { return nodes.filter(item => item !== node && node.contains(item) && item.matches(selector)); }}; nodes.push(node); return node; };
    const addCard = (parent, {name, aria, busy = false, alert = false}) => {
      const card = element({jsname: 'BThTkd'}, parent);
      element({jsname: 'XPtOyb', title: name, 'aria-label': aria, 'aria-busy': busy ? 'true' : null}, card);
      if (alert) element({role: 'alert'}, card);
      const branch = element({}, card);
      element({jsname: 'ua35De', jscontroller: 'PIVayb', role: 'button', 'aria-label': 'Remove ' + name}, branch);
    };
    const outer = element({});
    const inner = element({}, outer);
    const editor = element({role: 'textbox', contenteditable: 'true', 'aria-label': 'History is on'}, inner);
    const file = element({type: 'file'}, inner); file.isConnected = true;
    const document = {title: 'Fixture', querySelectorAll: selector => nodes.filter(item => item.matches(selector))};
    file.ownerDocument = document;
    nodes.forEach(node => { node.ownerDocument = document; });
    mutate({element, addCard, outer, inner, editor, file});
    return vm.runInNewContext(source, {document, top: {}, innerWidth: 800, innerHeight: 600, location: {href: 'https://example.test'}, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, TextEncoder, getComputedStyle: () => ({visibility: 'visible'})});
  };
  if (process.argv.includes('--sibling-remove')) {
    const output = {
      exact_outside: probeLive(({addCard, outer}) => addCard(outer, {name: 'foreign.md', aria: 'foreign.md, .'})),
      busy_outside: probeLive(({addCard, outer}) => addCard(outer, {name: 'foreign.md', aria: 'foreign.md, Uploading', busy: true})),
      missing_inside: probeLive(({addCard, inner}) => addCard(inner, {name: 'foreign.md', aria: 'foreign.md, Uploading', busy: true})),
      mixed: probeLive(({addCard, inner}) => { addCard(inner, {name: 'foreign.md', aria: 'foreign.md, Uploading', busy: true}); addCard(inner, {name: 'owned.md', aria: 'owned.md, .'}); })
    };
    process.stdout.write(JSON.stringify(output) + '\n');
    process.exit(0);
  }
  if (process.argv.includes('--unsupported-label')) {
    const output = {
      inside: probeLive(({addCard, inner}) => addCard(inner, {name: 'foreign.md', aria: 'foreign.md, Uploading', busy: true})),
      outside: probeLive(({addCard, outer}) => addCard(outer, {name: 'foreign.md', aria: 'foreign.md, Uploading', busy: true})),
      mixed: probeLive(({addCard, inner, outer}) => { addCard(outer, {name: 'foreign.md', aria: 'foreign.md, Upload failed', alert: true}); addCard(inner, {name: 'owned.md', aria: 'owned.md, .'}); })
    };
    process.stdout.write(JSON.stringify(output) + '\n');
    process.exit(0);
  }
  const output = {
    foreign: probeLive(({addCard, outer}) => addCard(outer, {name: 'foreign.md', aria: 'foreign.md, .'})),
    pending: probeLive(({addCard, outer}) => addCard(outer, {name: 'foreign.md', aria: 'foreign.md, Uploading', busy: true})),
    mixed: probeLive(({addCard, inner, outer}) => { addCard(outer, {name: 'foreign.md', aria: 'foreign.md, .'}); addCard(inner, {name: 'owned.md', aria: 'owned.md, .'}); })
  };
  process.stdout.write(JSON.stringify(output) + '\n');
  process.exit(0);
}
if (process.argv.includes('--boundary-states')) {
  const boundaryState = ({nested = false, toolbar = false, foreign = false, absent = false} = {}) => {
    const nodes = [];
    const element = (attributes, parent = null) => { const node = {attributes, parentElement: parent, childNodes: [], getAttribute: key => attributes[key] ?? null, getClientRects: () => [{}], contains(item) { for (let current = item; current; current = current.parentElement) if (current === node) return true; return false; }, closest(selector) { return attributes['data-composer-boundary'] && selector === '[data-composer-boundary]' ? node : parent?.closest(selector) ?? null; }, matches: selector => selector.includes('toolbar') && attributes.role === 'toolbar', querySelectorAll(selector) { return nodes.filter(item => item !== node && node.contains(item) && (selector === 'input[type="file"]' ? item.attributes.type === 'file' : selector.includes('toolbar') ? item.attributes.role === 'toolbar' : selector.includes('button') ? item.attributes.role === 'button' : !!item.attributes.title)); }}; nodes.push(node); return node; };
    const boundary = absent ? null : element({'data-composer-boundary': 'true'});
    const inner = nested && boundary ? element({'data-composer-boundary': 'true'}, boundary) : boundary;
    const editor = element({role: 'textbox', 'aria-label': 'History is on'}, inner);
    editor.childNodes = []; editor.querySelector = () => null; editor.querySelectorAll = () => [];
    const file = boundary ? element({type: 'file'}, boundary) : null;
    if (file) { file.isConnected = true; file.ownerDocument = null; }
    if (toolbar && boundary) element({role: 'toolbar', title: 'Settings', 'aria-label': 'Settings'}, boundary);
    if (foreign && boundary) element({title: 'foreign.md', 'aria-label': 'foreign.md, .'}, boundary);
    const document = {title: 'Fixture', querySelectorAll: selector => selector.includes('textbox') ? [editor] : selector === 'input[type="file"]' ? (file ? [file] : []) : selector.includes('toolbar') ? nodes.filter(item => item.attributes.role === 'toolbar') : selector.includes('[title]') ? nodes.filter(item => item.attributes.title) : []};
    if (file) file.ownerDocument = document;
    editor.parentElement = boundary;
    nodes.forEach(node => { node.ownerDocument = document; });
    if (file) file.ownerDocument = document;
    return vm.runInNewContext(source, {document, top: {}, innerWidth: 100, innerHeight: 100, location: {href: 'https://example.test'}, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, getComputedStyle: () => ({visibility: 'visible'})});
  };
  process.stdout.write(JSON.stringify({missing: boundaryState({absent: true}), nested: boundaryState({nested: true, foreign: true}), toolbar: boundaryState({toolbar: true}), foreign: boundaryState({foreign: true})}) + '\n');
}
if (specialMode) process.exit(0);
function signatureProbe(format, publication, markers = null) {
  function element(tag, attributes = {}, children = []) {
    const node = {
      nodeType: 1, tagName: tag.toUpperCase(), childNodes: children,
      getAttribute: name => attributes[name] ?? null,
      hasAttribute: name => Object.hasOwn(attributes, name),
      getClientRects: () => [{}], querySelector: () => null, querySelectorAll: () => [],
      matches: () => false,
      computed: {},
    };
    for (const child of children) child.parentElement = node;
    return node;
  }
  const text = value => ({nodeType: 3, nodeValue: value});
  const signature = '\u200b- sent by Fulcrum';
  let content = [text(signature)];
  if (format === 'bold') content = [element('strong', {}, content)];
  if (format === 'italic') content = [element('em', {}, content)];
  if (format === 'link') content = [element('a', {href: 'https://example.com'}, content)];
  if (format === 'inline-style') content = [element('span', {style: 'color: red'}, content)];
  if (format === 'split-bold') content = [element('b', {}, [text('\u200b- sent')]), text(' by Fulcrum')];
  if (format === 'class-italic') {
    content = [element('span', {class: 'emphasized'}, content)];
    content[0].computed.fontStyle = 'italic';
  }
  if (format === 'class-color' || format === 'class-medium') {
    content = [element('span', {class: 'emphasized'}, content)];
    content[0].computed[format === 'class-color' ? 'color' : 'fontWeight'] = format === 'class-color' ? 'red' : '500';
  }
  const hello = format === 'body-bold' ? element('strong', {}, [text('hello')]) : text('hello');
  const body = element('div', {'aria-label': 'History is on'}, [element('div', {}, [hello]), element('div'), element('div', {}, content)]);
  if (format === 'root-bold') body.computed.fontWeight = '700';
  const marker = shown => {
    const parent = {computed: {display: shown ? 'block' : 'none'}};
    return {
      parentElement: parent,
      computed: {display: 'inline-flex', visibility: 'visible', opacity: '1'},
      getClientRects: () => parent.computed.display === 'none' ? [] : [{}]
    };
  };
  const spinner = markers?.spinner ? marker(markers.spinner === 'visible') : null;
  const alert = markers?.alert ? marker(markers.alert === 'visible') : null;
  const busy = markers?.busy ? marker(markers.busy === 'visible') : null;
  const busyAncestor = markers?.busyAncestor ? marker(markers.busyAncestor === 'visible') : null;
  const topic = {getAttribute: name => ({'data-topic-id': 'topic-1', 'data-is-local-only': markers?.localOnly ?? 'false'}[name] ?? null)};
  const group = {
    getAttribute: name => ({'data-id': 'message-1', 'data-user-id': 'sender-1'}[name] ?? null),
    querySelectorAll: selector => {
      if (selector === '[jsname="bgckF"]') return [body];
      if (selector === '[role="progressbar"],[aria-busy="true"]') return [spinner, busy].filter(Boolean);
      if (selector === '[role="alert"],[role="alertdialog"]') return [alert].filter(Boolean);
      return [];
    },
    querySelector: selector => selector === '[role="progressbar"],[role="alert"],[aria-busy="true"]' ? [spinner, alert, busy].find(Boolean) ?? null : null,
    closest: selector => selector === '[data-topic-id]' ? topic : selector === '[aria-busy="true"]' ? busyAncestor : null
  };
  const document = {
    title: 'Fixture - Chat',
    querySelectorAll(selector) {
      if (selector === messageSelector) return publication ? [group] : [];
      if (selector === '[role="textbox"][contenteditable="true"]') return publication ? [] : [body];
      return [];
    }
  };
  const result = vm.runInNewContext(source, {
    document, top: {}, innerWidth: 1440, innerHeight: 1000, location: {href: 'https://chat.google.com/app/chat/EXAMPLE'},
    Node: {TEXT_NODE: 3, ELEMENT_NODE: 1},
    getComputedStyle: e => ({visibility: 'visible', fontWeight: '400', fontStyle: 'normal', textDecorationLine: 'none', color: 'black', ...e.computed})
  });
  return publication ? markers ? result.messages[0] : result.messages[0].body : result.editors[0];
}
const signatureBodies = Object.fromEntries(['plain', 'body-bold', 'bold', 'italic', 'link', 'inline-style', 'split-bold', 'class-italic', 'class-color', 'class-medium', 'root-bold'].map(format => [format, {
  composer: signatureProbe(format, false), publication: signatureProbe(format, true)
}]));
const publicationBodies = Object.fromEntries(Object.entries({
  hidden: {spinner: 'hidden'},
  visible: {spinner: 'visible'},
  alert: {alert: 'visible'},
  busy: {busy: 'visible'},
  busyAncestor: {busyAncestor: 'visible'},
  hiddenAlert: {alert: 'hidden'},
  hiddenBusy: {busy: 'hidden', busyAncestor: 'hidden'},
  local: {spinner: 'hidden', localOnly: 'true'}
}).map(([kind, markers]) => [kind, signatureProbe('plain', true, markers)]));
if (process.argv.includes('--signature-bodies')) {
  process.stdout.write(JSON.stringify(signatureBodies) + '\n');
} else if (process.argv.includes('--publication-bodies')) {
  process.stdout.write(JSON.stringify(publicationBodies) + '\n');
} else {
  for (const [format, bodies] of Object.entries(signatureBodies)) {
    for (const body of Object.values(bodies)) {
      assert.equal(body.signature_plain, ['plain', 'body-bold'].includes(format), `${format} attribution formatting`);
    }
  }
  process.stdout.write('22 signature probe assertions passed\n');
  for (const [kind, message] of Object.entries(publicationBodies)) {
    assert.equal(message.server, ['hidden', 'hiddenAlert', 'hiddenBusy'].includes(kind), `${kind} marker publication state`);
    assert.equal(Array.isArray(message.attachments) && message.attachments.length === 0, true, `${kind} returns empty grounded attachment inventory when no chips`);
  }
  assert.equal(publicationBodies.hidden.pending, false, 'A hidden parent removes the spinner layout rect despite its own visible computed style');
  assert.equal(publicationBodies.hidden.error, false);
  assert.equal(publicationBodies.hidden.topic_id, 'topic-1');
  assert.equal(publicationBodies.hidden.local_only, 'false');
  assert.equal(publicationBodies.visible.pending, true);
  assert.equal(publicationBodies.alert.error, true);
  assert.equal(publicationBodies.busyAncestor.pending, true);
  assert.equal(publicationBodies.local.local_only, 'true');
  process.stdout.write('16 publication probe assertions passed\n');
  // Live-observed uploading card: XPtOyb has title without aria-label yet while a visible progressbar is inside BThTkd.
  {
    const make = (tag, attrs = {}, parent = null) => {
      const node = {
        tagName: tag, parentElement: parent, childNodes: [],
        getAttribute: k => Object.hasOwn(attrs, k) ? attrs[k] : null,
        getAttributeNames: () => Object.keys(attrs).filter(k => attrs[k] != null),
        getClientRects: () => [{x: 10, y: 10, width: 40, height: 20}],
        contains(other) { for (let c = other; c; c = c.parentElement) if (c === node) return true; return false; },
        closest(sel) { for (let c = node; c; c = c.parentElement) if (c.matches(sel)) return c; return null; },
        matches(sel) {
          return sel.split(',').some(part => {
            const s = part.trim();
            if (s === '*') return true;
            if (s === 'button') return tag === 'BUTTON';
            if (s === '[role="button"]') return attrs.role === 'button';
            if (s === '[role="textbox"][contenteditable="true"]') return attrs.role === 'textbox' && attrs.contenteditable === 'true';
            if (s === 'input[type="file"]') return tag === 'INPUT' && attrs.type === 'file';
            if (s === '[role="progressbar"]') return attrs.role === 'progressbar';
            if (s === '[aria-busy="true"]') return attrs['aria-busy'] === 'true';
            if (s === '[role="alert"]') return attrs.role === 'alert';
            if (s === '[jsname="BThTkd"]') return attrs.jsname === 'BThTkd';
            if (s === '[jsname="XPtOyb"]') return attrs.jsname === 'XPtOyb';
            if (s === '[jsname="ua35De"]') return attrs.jsname === 'ua35De';
            if (s === '[title]') return attrs.title != null;
            return false;
          });
        },
        querySelectorAll(sel) {
          const out = [];
          const walk = n => { for (const ch of n.childNodes) { if (ch.matches(sel)) out.push(ch); walk(ch); } };
          walk(node);
          return out;
        },
        querySelector(sel) { return node.querySelectorAll(sel)[0] || null; }
      };
      if (parent) parent.childNodes.push(node);
      return node;
    };
    const doc = make('DOCUMENT', {});
    doc.title = 'Live Pending - Chat';
    doc.defaultView = {};
    doc.defaultView.top = doc.defaultView;
    const boundary = make('DIV', {jsname: 'ZQsur'}, doc);
    make('DIV', {role: 'textbox', contenteditable: 'true', 'aria-label': 'History is on'}, boundary);
    const input = make('INPUT', {type: 'file', role: 'button'}, boundary);
    input.isConnected = true; input.ownerDocument = doc;
    const shelf = make('DIV', {jsname: 'qaclne', jscontroller: 'WCjcW'}, boundary);
    const card = make('DIV', {jsname: 'BThTkd'}, shelf);
    make('DIV', {jsname: 'XPtOyb', title: 'uploading.md'}, card);
    make('DIV', {role: 'progressbar', jsname: 'LbNpof'}, card);
    make('BUTTON', {jsname: 'ua35De', jscontroller: 'PIVayb', 'aria-label': 'Remove uploading.md'}, card);
    const res = vm.runInNewContext(source, {
      document: doc, top: doc.defaultView, location: {href: 'https://chat.google.com/app/chat/EXAMPLE'},
      innerWidth: 1440, innerHeight: 1000, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, TextEncoder,
      getComputedStyle: () => ({visibility: 'visible'})
    });
    assert.equal(res.composer_boundary, 'supported', 'Live uploading card with visible progressbar and null XPtOyb aria-label stays supported');
    assert.deepEqual(JSON.parse(JSON.stringify(res.composer_attachments)), [{name: 'uploading.md', pending: true, error: false, removable: false}]);
  // Also assert the attachment negative-predicate, sibling-remove, and unsupported-label modes without needing Python.
  const { execFileSync } = require('node:child_process');
  const runMode = flag => JSON.parse(execFileSync(process.execPath, [__filename, flag], { encoding: 'utf8' }));
  const predicates = runMode('--diagnostic-predicates');
  assert.equal(predicates.positive.status, 'recognized');
  assert.deepEqual(predicates.positive.anomalies, []);
  assert.equal(predicates.depth_four.status, 'recognized');
  assert.equal(predicates.history_card.status, 'recognized');
  for (const name of ['nested_marker', 'extra_title', 'wrong_image', 'ancestor_synthetic', 'deep_remove', 'depth_five', 'busy_ancestor', 'orphan_synthetic', 'orphan_remove', 'wrong_tag_card', 'wrong_editor', 'framed_file', 'image_ua35', 'busy_false', 'busy_empty', 'filename_settings', 'image_details', 'borrowed_remove', 'borrowed_remove_alone', 'live_nested_card']) {
    assert.equal(predicates[name].boundary, 'unsupported', `${name} must stay unsupported`);
    assert.equal(predicates[name].attachments, null, `${name} must withhold attachments`);
    assert.equal(predicates[name].status, 'withheld', `${name} status must be withheld`);
    assert.deepEqual(predicates[name].cards, [], `${name} cards must be empty`);
    assert.ok(predicates[name].anomalies.length > 0, `${name} must record anomalies`);
  }
  assert.equal(predicates.historical_nested_card.boundary, 'unsupported');
  assert.equal(predicates.historical_nested_card.status, 'withheld');
  const sibling = runMode('--sibling-remove');
  for (const name of ['exact_outside', 'busy_outside', 'missing_inside', 'mixed']) {
    assert.equal(sibling[name].composer_boundary, 'unsupported', `sibling-remove ${name} must be unsupported`);
    assert.equal(sibling[name].composer_attachments, null, `sibling-remove ${name} must withhold attachments`);
  }
  const unsupportedLabel = runMode('--unsupported-label');
  for (const place of ['inside', 'outside', 'mixed']) {
    assert.equal(unsupportedLabel[place].composer_boundary, 'unsupported', `unsupported-label ${place} must be unsupported`);
    assert.equal(unsupportedLabel[place].composer_attachments, null, `unsupported-label ${place} must withhold attachments`);
  }
  process.stdout.write('28 attachment negative-predicate assertions passed\n');
  }
}
