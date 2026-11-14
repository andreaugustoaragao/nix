function textContent(content) {
  if (typeof content === 'string') return content;
  return (Array.isArray(content) ? content : [])
    .filter(part => part && ['text', 'input_text', 'output_text'].includes(part.type) && typeof part.text === 'string')
    .map(part => part.text).join('\n\n');
}

function userQuestion(message, text) {
  let wrappedImages = 0;
  // Codex wraps clipboard images in metadata that is not part of the question.
  const readable = text.replace(/<image\s+name=\[Image #\d+\]\s+path="[^"]*"\s*>[\s\S]*?<\/image>/g, () => {
    wrappedImages++;
    return "";
  }).trim();
  const images = Array.isArray(message.content)
    ? message.content.filter(part => part && ['image', 'input_image'].includes(part.type)).length : 0;
  const count = Math.max(wrappedImages, images);
  if (!count) return readable;
  const label = count === 1 ? 'Image attached' : count + ' images attached';
  return label + (readable ? ' · ' + readable : '');
}

// Keep the last user question with every answer, including intermediate updates.
export function assistantReplies(messages) {
  const replies = [];
  let question = '';
  for (const message of messages) {
    if (!message || !['user', 'assistant'].includes(message.role)) continue;
    const text = textContent(message.content);
    if (message.role === 'user') {
      if (/^<hc(?:\s|>)[\s\S]*<\/hc>\s*$/.test(text.trim())) continue;
      // Claude wraps tool results in user messages; those are not new questions.
      if (!text.trim() && Array.isArray(message.content) && message.content.some(part => part?.type === 'tool_result')) continue;
      question = userQuestion(message, text);
      continue;
    }
    if (!text.trim()) continue;
    const reply = { id: String(message.id || message.timestamp || replies.length), text };
    if (question) reply.question = question;
    if (replies.at(-1)?.id === reply.id) replies[replies.length - 1] = reply;
    else replies.push(reply);
  }
  return replies.slice(-40);
}
