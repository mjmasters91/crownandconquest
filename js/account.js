import { banReasonFrom, migrationMissing, playerEmail, validatePassword, validateUsername } from "./account-logic.js";

// Same Supabase project as Toon Orbit Battle and Aetherfall.
// This is the publishable key already shipped in the client. Never put a service_role key here.
const URL = "https://orbzytpukjywqkbkbtcs.supabase.co";
const PUBLISHABLE_KEY = "sb_publishable_g6lbXdi9r10i5d6TvHquaw_drhIG58X";

let client = null;

export function accountClient() {
  const lib = globalThis.supabase;
  if (!lib?.createClient) return null;
  if (!client) {
    client = lib.createClient(URL, PUBLISHABLE_KEY, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
    });
  }
  return client;
}

function friendlyAuth(error) {
  const msg = error?.message || "Something went wrong. Try again.";
  if (/failed to fetch|network|offline|load failed/i.test(msg)) return "You appear to be offline.";
  if (/invalid login|invalid credentials/i.test(msg)) return "Wrong username or password.";
  if (/already registered|already been registered|user already/i.test(msg)) return "That username is taken.";
  if (/email not confirmed/i.test(msg)) return "Confirm email is still on for this project. Turn it off, then try again.";
  return msg;
}

export function fromRpcError(error) {
  const banned = banReasonFrom(error);
  if (banned) return { ok: false, banned: true, reason: banned, error: `This account is banned. ${banned}` };
  if (migrationMissing(error)) {
    return {
      ok: false,
      missing: true,
      error: "Crown & Conquest is not on this server yet. You can still walk a demo realm on this device.",
    };
  }
  return { ok: false, error: error?.message || "The server did not answer." };
}

export async function rpc(name, args) {
  const db = accountClient();
  if (!db) return { ok: false, error: "The account library did not load." };
  const { data, error } = await db.rpc(name, args || {});
  if (error) return fromRpcError(error);
  return { ok: true, data };
}

export async function currentSession() {
  const db = accountClient();
  if (!db) return null;
  const { data, error } = await db.auth.getSession();
  if (error) throw error;
  return data.session || null;
}

export async function signUpAccount(username, password) {
  const name = validateUsername(username);
  if (name.error) return { ok: false, error: name.error };
  const pass = validatePassword(password);
  if (pass.error) return { ok: false, error: pass.error };
  const db = accountClient();
  if (!db) return { ok: false, error: "The account library did not load." };
  const { data, error } = await db.auth.signUp({
    email: playerEmail(name.username),
    password: pass.password,
    options: { data: { username: name.username } },
  });
  if (error) return { ok: false, error: friendlyAuth(error) };
  if (!data?.session) {
    return { ok: false, error: "Confirm email is still on, so this account cannot sign in yet." };
  }
  return { ok: true };
}

export async function logInAccount(username, password) {
  const name = validateUsername(username);
  if (name.error) return { ok: false, error: name.error };
  const pass = validatePassword(password);
  if (pass.error) return { ok: false, error: pass.error === "Enter a password." ? pass.error : "Wrong username or password." };
  const db = accountClient();
  if (!db) return { ok: false, error: "The account library did not load." };
  const { error } = await db.auth.signInWithPassword({
    email: playerEmail(name.username),
    password: pass.password,
  });
  if (error) return { ok: false, error: friendlyAuth(error) };
  return { ok: true };
}

export async function logOutAccount() {
  const db = accountClient();
  if (db) await db.auth.signOut();
}
