export function expired(data, now = Date.now()) {
  return !data || now > Date.parse(data.horizon_end);
}

export function shouldNotify(data, previous, now = Date.now()) {
  return Boolean(data && data.notify && data.attention !== "routine" &&
    data.run_id !== previous && !expired(data, now));
}

export function localSourcePath(url, origin) {
  try {
    const rooted = url.startsWith("intake-note:");
    const target = decodeURIComponent((rooted ? url.slice(12) : url).split("#")[0]);
    if (target.startsWith("/") || target.includes(":") || !/\.(md|json)$/.test(target)) return null;
    const parts = rooted ? [] : (origin || "").split("/").slice(0, -1);
    for (const part of target.split("/")) {
      if (!part || part === ".") continue;
      if (part === "..") { if (!parts.length) return null; parts.pop(); }
      else parts.push(part);
    }
    return parts.join("/");
  } catch { return null; }
}

export function visibleItems(items, filter) {
  return items.filter(item => filter === "all" || (filter === "decision" ? item.kind === "decision" && item.effective_status !== "done" : filter === "snoozed" ? item.followup?.status === "snoozed" && item.effective_status !== "done" : item.effective_status === filter));
}

export function historyPage(reports, offset, size) {
  return {items:reports.slice(offset,offset+size),hasNewer:offset>0,hasOlder:offset+size<reports.length};
}
