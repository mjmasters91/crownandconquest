/** Pure account checks. No network, so node tests can import this file. */

export function validateUsername(name) {
  const username = String(name || "").trim();
  if (!/^[A-Za-z0-9_]{3,20}$/.test(username)) {
    return { error: "Use 3-20 letters, numbers, or underscores." };
  }
  return { username };
}

export function validateEmail(email) {
  const value = String(email || "").trim();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value) || value.includes(" ")) {
    return { error: "Enter a valid email." };
  }
  return { email: value };
}

export function validatePassword(password, confirm) {
  const pass = String(password || "");
  if (pass.length < 6) return { error: "Password needs at least 6 characters." };
  if (pass.length > 72) return { error: "Password needs to be 72 characters or fewer." };
  if (confirm != null && pass !== String(confirm)) return { error: "Passwords do not match." };
  return { password: pass };
}

export function signupFailureMessage(message) {
  const text = String(message || "");
  if (/database error saving new user/i.test(text)) return "That username is taken.";
  if (/already registered|already been registered|user already/i.test(text)) return "That email is already registered.";
  return text || "Could not create the account.";
}
