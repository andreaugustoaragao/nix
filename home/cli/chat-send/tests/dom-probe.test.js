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
if (!process.argv.includes('--signature-bodies')) process.stdout.write('9 DOM probe fixture assertions passed\n');

function signatureProbe(format, publication) {
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
  const group = {
    getAttribute: name => ({'data-id': 'message-1', 'data-user-id': 'sender-1'}[name] ?? null),
    querySelectorAll: selector => selector === '[jsname="bgckF"]' ? [body] : [],
    querySelector: () => null,
    closest: selector => selector === '[data-topic-id]' ? {getAttribute: () => 'false'} : null
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
  return publication ? result.messages[0].body : result.editors[0];
}
const signatureBodies = Object.fromEntries(['plain', 'body-bold', 'bold', 'italic', 'link', 'inline-style', 'split-bold', 'class-italic', 'class-color', 'class-medium', 'root-bold'].map(format => [format, {
  composer: signatureProbe(format, false), publication: signatureProbe(format, true)
}]));
if (process.argv.includes('--signature-bodies')) {
  process.stdout.write(JSON.stringify(signatureBodies) + '\n');
} else {
  for (const [format, bodies] of Object.entries(signatureBodies)) {
    for (const body of Object.values(bodies)) {
      assert.equal(body.signature_plain, ['plain', 'body-bold'].includes(format), `${format} attribution formatting`);
    }
  }
  process.stdout.write('22 signature probe assertions passed\n');
}
