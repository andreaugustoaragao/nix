(() => {
  // Read-only public DOM adapter. Grounding: T002 dom-publication-v2.json.
  const rectOffscreen = r => {
    const left = r.left ?? r.x;
    const top = r.top ?? r.y;
    const right = r.right ?? (Number.isFinite(left) && Number.isFinite(r.width) ? left + r.width : undefined);
    const bottom = r.bottom ?? (Number.isFinite(top) && Number.isFinite(r.height) ? top + r.height : undefined);
    if (![left, top, right, bottom].every(Number.isFinite)) return false;
    const vw = typeof innerWidth === 'number' && innerWidth > 0 ? innerWidth : document.documentElement?.clientWidth || 0;
    const vh = typeof innerHeight === 'number' && innerHeight > 0 ? innerHeight : document.documentElement?.clientHeight || 0;
    return right <= 0 || bottom <= 0 || (vw > 0 && left >= vw) || (vh > 0 && top >= vh);
  };
  const visible = e => {
    const rects = e.getClientRects();
    if (!rects.length || getComputedStyle(e).visibility === 'hidden') return false;
    const ariaHidden = e.getAttribute?.('aria-hidden') === 'true' || !!e.closest?.('[aria-hidden="true"]');
    return !(ariaHidden && Array.from(rects).every(rectOffscreen));
  };
  const all = (root, selector) => Array.from(root.querySelectorAll(selector));
  const messageSelector = '[role="group"][data-id][data-user-id][data-message-multiplat-item-id]';
  const blockingDialog = e => {
    const rect = e.getBoundingClientRect();
    const rectHidden = e.getAttribute?.('aria-hidden') === 'true' || !!e.closest?.('[aria-hidden="true"]');
    const offscreen = rectOffscreen(rect) || (rect.right <= 0 || rect.bottom <= 0 || rect.left >= innerWidth || rect.top >= innerHeight);
    if (rectHidden && offscreen) return false;
    return e.getAttribute('role') === 'alertdialog' ||
      e.getAttribute('aria-modal') === 'true' || !e.closest(messageSelector);
  };
  const marker = (root, selector) => [root, ...all(root, selector)].filter(item => item.matches?.(selector)).some(visible);
  const signature = '- sent by Fulcrum';
  const chipSelector = 'span[data-user-email][contenteditable="false"]';
  const chip = e => ({
    email: e.getAttribute('data-user-email'), user_id: e.getAttribute('data-user-id'),
    member_id: e.getAttribute('data-member-id'), display: e.getAttribute('data-display-name'),
    mention_type: e.getAttribute('data-user-mention-type'),
    selected: ['0', '3'].includes(e.getAttribute('data-user-mention-type')) &&
      !!e.getAttribute('data-user-id') && !!e.getAttribute('data-member-id')
  });
  const text = node => {
    if (node.nodeType === Node.TEXT_NODE) return node.nodeValue;
    if (node.nodeType !== Node.ELEMENT_NODE) return '';
    if (node.matches('script,style,button,[role="button"],[role="toolbar"],[aria-hidden="true"]')) return '';
    if (node.tagName === 'BR') return '\n';
    const value = Array.from(node.childNodes).map(text).join('');
    return ['DIV', 'P', 'LI', 'BLOCKQUOTE'].includes(node.tagName) ? value + '\n' : value;
  };
  const semantic = root => {
    const blocks = [];
    let pending = '';
    let styledRanges = [];
    let signaturePlain = true;
    const baseStyle = getComputedStyle(root);
    const styled = node => {
      for (let e = node.parentElement; e; e = e.parentElement) {
        const css = getComputedStyle(e);
        if (['B', 'STRONG', 'I', 'EM', 'A', 'U', 'S', 'STRIKE', 'DEL', 'INS', 'CODE', 'MARK', 'SUB', 'SUP', 'SMALL', 'BIG', 'FONT'].includes(e.tagName) ||
            (e !== root && !!e.getAttribute('style')?.trim()) ||
            ['bold', 'bolder'].includes(css.fontWeight) || Number(css.fontWeight) > 500 ||
            (css.fontStyle && css.fontStyle !== 'normal') ||
            (css.textDecorationLine && css.textDecorationLine !== 'none') ||
            ['fontWeight', 'fontSize', 'fontFamily', 'fontVariant', 'color', 'textTransform', 'letterSpacing', 'wordSpacing', 'textShadow'].some(key => css[key] && css[key] !== baseStyle[key])) return true;
        if (e === root) break;
      }
      return false;
    };
    const flush = () => {
      for (let at = pending.indexOf(signature); at !== -1; at = pending.indexOf(signature, at + signature.length)) {
        if (styledRanges.some(([start, end]) => start < at + signature.length && end > at)) signaturePlain = false;
      }
      if (pending) blocks.push({type: 'text', text: pending});
      pending = ''; styledRanges = [];
    };
    const walk = node => {
      if (node.nodeType === Node.TEXT_NODE) {
        if (styled(node)) styledRanges.push([pending.length, pending.length + node.nodeValue.length]);
        pending += node.nodeValue; return;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      if (node.matches(chipSelector)) {
        flush(); blocks.push({type: 'mention', ...chip(node)}); return;
      }
      if (node.matches('script,style,button,[role="button"],[role="toolbar"],[aria-hidden="true"]')) return;
      if (node.matches('article[role="code"]')) {
        flush(); blocks.push({type: 'code', text: node.innerText}); return;
      }
      if (node.tagName === 'BR') { pending += '\n'; return; }
      Array.from(node.childNodes).forEach(walk);
      if (['DIV', 'P', 'LI', 'BLOCKQUOTE'].includes(node.tagName)) pending += '\n';
    };
    Array.from(root.childNodes).forEach(walk); flush();
    return {
      blocks,
      text: text(root),
      forbidden: !!root.querySelector('li,blockquote'),
      signature_list: all(root, 'li').some(e => e.textContent.includes(signature)),
      signature_plain: signaturePlain,
      mentions: all(root, chipSelector).map(chip),
    };
  };
  const messageAttachments = group => {
    const groundedPublishedButton = btn => {
      const name = btn?.getAttribute('title')?.trim();
      const aria = btn?.getAttribute('aria-label')?.trim();
      return !!name && !!aria && aria.includes(name);
    };
    const groundedChip = chipRoot =>
      chipRoot?.getAttribute('jsname') === 'sBlcJe' && chipRoot.getAttribute('data-chip-index') != null &&
      (() => {
        const buttons = all(chipRoot, 'button,[role="button"]').filter(btn => btn.getAttribute('data-action') === '7');
        return buttons.length === 1 && groundedPublishedButton(buttons[0]);
      })();
    const chipMarkers = all(group, '[jsname="sBlcJe"]');
    const indexMarkers = all(group, '[data-chip-index]');
    const actionMarkers = all(group, '[data-action="7"]');
    const cardMarkers = all(group, '[jsname="BThTkd"]');
    const groundedChips = chipMarkers.filter(groundedChip);
    const markerPresent = chipMarkers.length || indexMarkers.length || actionMarkers.length || cardMarkers.length;
    if (!markerPresent) return [];
    if (chipMarkers.some(chip => !groundedChip(chip))) return null;
    if (indexMarkers.some(node => !groundedChips.some(chip => chip.contains?.(node)))) return null;
    if (actionMarkers.some(node => !groundedChips.some(chip => chip.contains?.(node)))) return null;
    for (const card of cardMarkers) {
      const buttons = all(card, 'button,[role="button"]').filter(btn => btn.getAttribute('data-action') === '7');
      if (buttons.length !== 1 || !groundedPublishedButton(buttons[0])) return null;
    }
    if (!groundedChips.length) return null;
    return groundedChips.map(chipRoot => {
      const btn = all(chipRoot, 'button,[role="button"]').find(node => node.getAttribute('data-action') === '7');
      const name = btn.getAttribute('title').trim();
      return {
        name,
        pending: marker(chipRoot, '[aria-busy="true"],[role="progressbar"]'),
        error: marker(chipRoot, '[role="alert"]')
      };
    });
  };
  const groups = all(document, messageSelector);
  const headings = all(document, '[data-message-id][data-hovercard-id]');
  const identities = headings.map(e => ({
    message_id: e.getAttribute('data-message-id'), email: e.getAttribute('data-hovercard-id')
  }));
  const messages = groups.slice(-40).map(group => {
    const bodies = all(group, '[jsname="bgckF"]');
    const chips = all(group, '[jsname="sBlcJe"][data-chip-index]');
    const attachmentOnly = bodies.length === 0 && chips.length > 0 && chips.every(chip => {
      const buttons = all(chip, 'button,[role="button"]').filter(btn => btn.getAttribute('data-action') === '7');
      if (buttons.length !== 1) return false;
      const name = buttons[0].getAttribute('title')?.trim();
      const aria = buttons[0].getAttribute('aria-label')?.trim();
      return !!name && !!aria && aria.includes(name);
    });
    const topic = group.closest('[data-topic-id]');
    const busyAncestor = group.closest('[aria-busy="true"]');
    const pending = all(group, '[role="progressbar"],[aria-busy="true"]').some(visible) ||
      !!(busyAncestor && visible(busyAncestor));
    const error = all(group, '[role="alert"],[role="alertdialog"]').some(visible);
    const localOnly = topic?.getAttribute('data-is-local-only') ?? null;
    return {
      id: group.getAttribute('data-id'), sender_id: group.getAttribute('data-user-id'),
      body_count: bodies.length,
      attachment_only: attachmentOnly,
      topic_id: topic?.getAttribute('data-topic-id') ?? null,
      local_only: localOnly, pending, error,
      server: localOnly === 'false' && !pending && !error,
      body: bodies.length === 1 ? semantic(bodies[0]) : null,
      attachments: messageAttachments(group)
    };
  });
  const editors = all(document, '[role="textbox"][contenteditable="true"]').filter(visible);
  const composerInventory = editors => {
    const unmetGates = ['G1_empty_and_controls', 'E1_upload_trial', 'E2_remove_trial', 'G4_other_labels', 'G5_published_inventory'];
    const withheld = (preconditions_ok, cards, anomalies, status) => ({
      boundary: 'unsupported',
      attachments: null,
      diagnostics: {preconditions_ok, status, cards, anomalies, unmet_gates: unmetGates}
    });
    const files = all(document, 'input[type="file"]').filter(e => e.isConnected && e.ownerDocument === document && (!e.ownerDocument.defaultView || e.ownerDocument.defaultView === e.ownerDocument.defaultView.top));
    if (editors.length !== 1 || files.length !== 1) return withheld(false, [], ['malformed_card_or_marker'], 'withheld');
    let boundary = editors[0];
    while (boundary && !boundary.contains?.(files[0])) boundary = boundary.parentElement;
    if (!boundary || boundary.closest?.(messageSelector) || all(boundary, messageSelector).length) return withheld(false, [], ['malformed_card_or_marker'], 'withheld');
    const preconditions = editors.length === 1 && editors[0].getAttribute('aria-label') === 'History is on' && files.length === 1 && !!boundary &&
      !boundary.closest?.(messageSelector) && !editors[0].closest?.(messageSelector) && !files[0].closest?.(messageSelector) && all(boundary, messageSelector).length === 0;
    const outsideHistory = node => !!node && !node.closest?.(messageSelector);
    const depth = (node, root) => { let count = 0; for (let current = node; current && current !== root; current = current.parentElement) count += 1; return count; };
    const filenameBytes = value => new TextEncoder().encode(value || '').length;
    const diagnosticName = node => {
      const name = (node?.getAttribute('title') || '').trim();
      const bytes = filenameBytes(name);
      return bytes >= 1 && bytes <= 180 && !/[/\u0000]/.test(name) && ![...name].some(char => char.charCodeAt(0) < 32 || char.charCodeAt(0) === 127) && name !== '.' && name !== '..' ? name : '';
    };
    const attributeNames = node => typeof node.getAttributeNames === 'function' ? node.getAttributeNames() : Object.keys(node.attributes || {}).filter(key => key !== 'parentElement');
    const synthetic = node => attributeNames(node).some(name => name.startsWith('data-attachment') || name === 'data-composer-attachment');
    const groundedLabel = (name, node) => {
      const title = (node?.getAttribute('title') || '').trim();
      const aria = node?.getAttribute('aria-label') || '';
      return !!name && name === title && [name + ', .', name + ', PDF.', name + ', Image', name + ', Image.'].includes(aria);
    };
    const removeOk = (name, control) => control?.tagName === 'BUTTON' && control.getAttribute('aria-label') === 'Remove ' + name &&
      (control.getAttribute('jscontroller') === null || control.getAttribute('jscontroller') === 'PIVayb');
    const cards = [];
    const anomalies = [];
    const accepted = new Set();
    const fail = () => { anomalies.push('malformed_card_or_marker'); cards.length = 0; };
    if (preconditions) {
      for (const card of all(boundary, '[jsname="BThTkd"]')) {
        if (card.tagName !== 'DIV' || card.getAttribute('role') != null || !boundary.contains(card) || editors[0].contains(card)) { fail(); continue; }
        const filenames = all(card, '[jsname="XPtOyb"]').filter(node => node.parentElement === card && node.tagName === 'DIV');
        const filename = filenames.length === 1 ? filenames[0] : null;
        const name = filename ? diagnosticName(filename) : '';
        const images = filename ? all(filename, '[jscontroller="nqzCif"]').filter(node => node.tagName === 'IMG') : [];
        const imageValid = !images.length || (images.length === 1 && images[0].getAttribute('title') === name &&
          images[0].getAttribute('jsname') == null &&
          (images[0].getAttribute('alt') == null || images[0].getAttribute('alt') === name));
        const titled = all(card, '[title]');
        const titleValid = titled.every(node => node === filename || images.includes(node));
        const removes = all(card, '[jsname="ua35De"]').filter(node => removeOk(name, node) && depth(node, card) >= 1 && depth(node, card) <= 4);
        const remove = removes.length === 1 ? removes[0] : null;
        const ancestorBad = (() => {
          for (let current = card.parentElement; current && boundary.contains(current); current = current.parentElement) {
            if (current !== card && current.getAttribute('jsname') === 'BThTkd') return true;
            if (['XPtOyb', 'ua35De'].includes(current.getAttribute('jsname')) || current.getAttribute('jscontroller') === 'nqzCif' || synthetic(current)) return true;
            if (attributeNames(current).includes('aria-busy') || (current.matches?.('[role="progressbar"],[role="alert"]') && visible(current))) return true;
          }
          return false;
        })();
        const marked = [card, ...all(card, '*')].some(node => synthetic(node) || (attributeNames(node).includes('aria-busy') && node.getAttribute('aria-busy') !== 'true'));
        const pending = marker(card, '[aria-busy="true"],[role="progressbar"]');
        const error = marker(card, '[role="alert"]');
        const labelOk = !!filename && (groundedLabel(name, filename) || (pending && filename.getAttribute('aria-label') == null));
        const exact = filenames.length === 1 && !!name && labelOk && filename.getAttribute('jsname') === 'XPtOyb' && imageValid && titleValid &&
          removes.length === 1 && remove && !filename.contains(remove) && removes.filter(node => (node.getAttribute('aria-label') || '').includes('Remove ' + name)).length === 1 &&
          !ancestorBad && !marked && card.getAttribute('jsname') === 'BThTkd';
        if (!exact) { fail(); continue; }
        cards.push({name, shape: 'bth_xpt_ua35_card', pending, error, removable: !pending && !error});
        [card, filename, remove, ...images].forEach(node => accepted.add(node));
      }
      if (new Set(cards.map(card => card.name)).size !== cards.length) fail();
    }
    const attachmentSelectors = ['[jsname="BThTkd"]', '[jsname="XPtOyb"]', '[jsname="ua35De"]', '[jscontroller="nqzCif"]', '[data-composer-attachment]', '[data-attachment-name]', '[data-attachment-card]'];
    for (const selector of attachmentSelectors) {
      for (const node of all(document, selector)) {
        if (!outsideHistory(node) || accepted.has(node)) continue;
        if (!boundary.contains(node)) { fail(); break; }
        fail(); break;
      }
      if (anomalies.length) break;
    }
    if (!anomalies.length) {
      for (const control of all(document, 'button,[role="button"]')) {
        if (!outsideHistory(control) || accepted.has(control)) continue;
        const label = control.getAttribute('aria-label') || '';
        if (label.startsWith('Remove ') && boundary.contains(control)) fail();
      }
    }
    if (!anomalies.length) {
      for (const node of all(document, '*')) {
        if (!outsideHistory(node) || accepted.has(node)) continue;
        if ((boundary.contains(node) && synthetic(node)) || (attributeNames(node).includes('aria-busy') && node.getAttribute('aria-busy') !== 'true')) fail();
      }
    }
    const diagCards = cards.map(({name, shape}) => ({name, shape}));
    const status = cards.length && !anomalies.length ? 'recognized' : anomalies.length ? 'withheld' : 'absent';
    if (!preconditions || anomalies.length) return withheld(preconditions, diagCards, anomalies, status);
    return {
      boundary: 'supported',
      attachments: cards.map(({name, pending, error, removable}) => ({name, pending, error, removable})),
      diagnostics: {preconditions_ok: true, status, cards: diagCards, anomalies: [], unmet_gates: unmetGates}
    };
  };
  const composer = composerInventory(editors);
  const send = all(document, 'button,[role="button"]').filter(e => visible(e) && e.getAttribute('aria-label') === 'Send message');
  const selection = document.getSelection?.();
  const anchor = selection?.anchorNode;
  return {
    version: 1, url: location.href, title: document.title,
    accounts: all(document, '[aria-label]').filter(e => visible(e) && e.getAttribute('aria-label').startsWith('Google Account:')).map(e => e.getAttribute('aria-label').replace(/\s+/g, ' ').trim()),
    editors: editors.map(e => ({name: e.getAttribute('aria-label'), ...semantic(e)})),
    file_input_count: all(document, 'input[type="file"]').filter(e => e.isConnected && e.ownerDocument === document && (!e.ownerDocument.defaultView || e.ownerDocument.defaultView === e.ownerDocument.defaultView.top)).length,
    composer_boundary: composer.boundary,
    composer_attachments: composer.attachments,
    attachment_diagnostics: composer.diagnostics,
    send_count: send.length,
    send_enabled: send.length === 1 && !send[0].disabled && send[0].getAttribute('aria-disabled') !== 'true',
    send_focused: send.length === 1 && document.activeElement === send[0],
    editor_focused: editors.length === 1 && document.activeElement === editors[0],
    caret_at_plain_end: editors.length === 1 && !!anchor && selection.isCollapsed &&
      editors[0].contains(anchor) && anchor.nodeType === Node.TEXT_NODE &&
      anchor.nodeValue === '\u200b' + signature && selection.anchorOffset === anchor.nodeValue.length &&
      !anchor.parentElement.closest('article[role="code"]'),
    dialogs: all(document, '[role="dialog"],[role="alertdialog"]').filter(visible).filter(blockingDialog).length,
    options: all(document, '[role="option"]').filter(visible).map(e => ({
      email: e.getAttribute('data-email'), id: e.id, chip_type: e.getAttribute('data-chip-type'),
      name: e.getAttribute('aria-label') || e.innerText
    })),
    message_ids: groups.map(e => e.getAttribute('data-id')),
    identities, messages,
    publication_supported: messages.some(m => m.body_count === 1) && messages.every(m => m.id && m.sender_id && (m.body_count === 1 || m.attachment_only)),
    truncated: groups.length > 2000 || identities.length > 2000 || editors.length > 4
  };
})()