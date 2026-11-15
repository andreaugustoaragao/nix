// Execute the actual read-only adapter against narrow DOM fixtures; no browser.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require('node:path').join(__dirname, '../scripts/dom_probe.js'), 'utf8');
const messageSelector = '[role="group"][data-id][data-user-id][data-message-multiplat-item-id]';

function probe(dialogs = [], codeText = null) {
  const group = {
    getAttribute: name => ({'data-id': 'old-message', 'data-user-id': 'sender-1'}[name] ?? null),
    closest: () => null, querySelector: () => null, querySelectorAll: () => []
  };
  const elements = dialogs.map(d => ({
    getAttribute: name => ({role: d.role || 'dialog', 'aria-modal': d.modal ?? null}[name] ?? null),
    closest: selector => d.embedded && selector === messageSelector ? group : null,
    getClientRects: () => d.hidden ? [] : [{x: 443, y: -141, width: 320, height: 308}]
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
    document, location: {href: 'https://chat.google.com/app/chat/EXAMPLE'},
    Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, getComputedStyle: () => ({visibility: 'visible'})
  });
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
const jsonMode = process.argv.includes('--signature-bodies') || process.argv.includes('--publication-bodies');
function focusProbe({code = false, collapsed = true, offset = 18, focus = 'send', count = 1} = {}) {
  const anchor = {nodeType: 3, nodeValue: '\u200b- sent by Fulcrum', parentElement: {closest: () => code ? {} : null}};
  const editor = {childNodes: [], getClientRects: () => [{}], getAttribute: () => null,
    querySelectorAll: () => [], querySelector: () => null, contains: node => node === anchor};
  const send = {getClientRects: () => [{}], getAttribute: name => name === 'aria-label' ? 'Send message' : null};
  const document = {title: 'Fixture - Chat', activeElement: focus === 'send' ? send : focus === 'editor' ? editor : null,
    getSelection: () => ({anchorNode: anchor, anchorOffset: offset, isCollapsed: collapsed}),
    querySelectorAll: selector => selector === '[role="textbox"][contenteditable="true"]' ? [editor] :
      selector === 'button,[role="button"]' ? Array(count).fill(send) : []};
  return vm.runInNewContext(source, {document, location: {href: 'https://example.com'},
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
if (!jsonMode) process.stdout.write('8 focus probe assertions passed\n');
if (!jsonMode) process.stdout.write('9 DOM probe fixture assertions passed\n');

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
    document, location: {href: 'https://chat.google.com/app/chat/EXAMPLE'},
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
}
