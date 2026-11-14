(() => {
  // Read-only public DOM adapter. Grounding: T002 dom-publication-v2.json.
  const visible = e => !!e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden';
  const all = (root, selector) => Array.from(root.querySelectorAll(selector));
  const messageSelector = '[role="group"][data-id][data-user-id][data-message-multiplat-item-id]';
  const blockingDialog = e => e.getAttribute('role') === 'alertdialog' ||
    e.getAttribute('aria-modal') === 'true' || !e.closest(messageSelector);
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
  const groups = all(document, messageSelector);
  const headings = all(document, '[data-message-id][data-hovercard-id]');
  const identities = headings.map(e => ({
    message_id: e.getAttribute('data-message-id'), email: e.getAttribute('data-hovercard-id')
  }));
  const messages = groups.slice(-40).map(group => {
    const bodies = all(group, '[jsname="bgckF"]');
    const topic = group.closest('[data-topic-id]');
    const pending = !!group.querySelector('[role="progressbar"],[role="alert"],[aria-busy="true"]') ||
      !!group.closest('[aria-busy="true"]');
    return {
      id: group.getAttribute('data-id'), sender_id: group.getAttribute('data-user-id'),
      body_count: bodies.length,
      server: topic?.getAttribute('data-is-local-only') === 'false' && !pending,
      body: bodies.length === 1 ? semantic(bodies[0]) : null
    };
  });
  const editors = all(document, '[role="textbox"][contenteditable="true"]').filter(visible);
  const send = all(document, 'button,[role="button"]').filter(e => visible(e) && e.getAttribute('aria-label') === 'Send message');
  return {
    version: 1, url: location.href, title: document.title,
    accounts: all(document, '[aria-label]').filter(e => visible(e) && e.getAttribute('aria-label').startsWith('Google Account:')).map(e => e.getAttribute('aria-label')),
    editors: editors.map(e => ({name: e.getAttribute('aria-label'), ...semantic(e)})),
    send_count: send.length,
    send_enabled: send.length === 1 && !send[0].disabled && send[0].getAttribute('aria-disabled') !== 'true',
    // Historical attachment cards expose nonmodal dialogs inside real message groups.
    dialogs: all(document, '[role="dialog"],[role="alertdialog"]').filter(visible).filter(blockingDialog).length,
    options: all(document, '[role="option"]').filter(visible).map(e => ({
      email: e.getAttribute('data-email'), id: e.id, chip_type: e.getAttribute('data-chip-type'),
      name: e.getAttribute('aria-label') || e.innerText
    })),
    message_ids: groups.map(e => e.getAttribute('data-id')),
    identities, messages,
    publication_supported: messages.length > 0 && messages.every(m => m.id && m.sender_id && m.body_count === 1),
    truncated: groups.length > 2000 || identities.length > 2000 || editors.length > 4
  };
})()
