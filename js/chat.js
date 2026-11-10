/** Chat rules shared by the demo hall and the checks the server repeats. */

export const CHAT_CHANNELS = ["global", "realm", "alliance"];

export function cleanChatBody(body) {
  const text = String(body || "").replace(/\s+/g, " ").trim();
  if (!text) return { error: "Say something." };
  if ([...text].length > 300) return { error: "Keep it to 300 characters." };
  return { body: text };
}

export function chatRateError(messages, playerKey, now) {
  const mine = (messages || []).filter((row) => row.playerKey === playerKey && !row.deleted);
  let last = 0;
  let recent = 0;
  for (const row of mine) {
    const at = row.createdAt || 0;
    if (at > last) last = at;
    if (now - at < 60000) recent += 1;
  }
  if (last && now - last < 3000) return "Wait a moment before speaking again.";
  if (recent >= 20) return "You have said enough for this minute.";
  return "";
}

export function unreadCount(messages, seenId) {
  let n = 0;
  for (const row of messages || []) {
    if (!row.deleted && row.id > (seenId || 0)) n += 1;
  }
  return n;
}
