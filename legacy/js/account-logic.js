/** Pure account helpers. No network, so node tests can import this file. */

export const PLAYER_EMAIL_DOMAIN = "@players.toonorbit.app";

export function validateUsername(username) {
  const name = String(username || "").trim();
  if (!name) return { error: "Enter a username." };
  if (!/^[A-Za-z0-9_]{3,16}$/.test(name)) return { error: "Use 3-16 letters, numbers, or underscores." };
  if (name.toLowerCase() === "guest") return { error: "That username is reserved." };
  return { username: name };
}

export function validatePassword(password) {
  const pass = String(password || "");
  if (!pass) return { error: "Enter a password." };
  if (pass.length < 6) return { error: "Password needs at least 6 characters." };
  if (pass.length > 128) return { error: "Password needs to be 128 characters or fewer." };
  return { password: pass };
}

export function playerEmail(username) {
  return String(username || "").trim().toLowerCase() + PLAYER_EMAIL_DOMAIN;
}

export function migrationMissing(error) {
  const message = String(error?.message || error || "");
  const code = String(error?.code || "");
  return /PGRST202|PGRST205|42883|42P01|does not exist|Could not find the function|schema cache/i.test(`${code} ${message}`);
}

export function banReasonFrom(error) {
  const message = String(error?.message || error || "");
  const match = message.match(/banned:\s*(.*)$/i);
  if (!match && !/banned/i.test(message)) return null;
  return (match?.[1] || "").trim() || "No reason was recorded.";
}
