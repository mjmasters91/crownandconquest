import assert from "node:assert/strict";
import test from "node:test";
import { banReasonFrom, migrationMissing, playerEmail, validatePassword, validateUsername } from "../js/account-logic.js";

test("shared toon orbit usernames", () => {
  assert.equal(playerEmail("MjMasters91"), "mjmasters91@players.toonorbit.app");
  assert.equal(validateUsername("ab").error.includes("3-16"), true);
  assert.equal(validateUsername("ada_ok").username, "ada_ok");
  assert.equal(validatePassword("short").error.includes("6"), true);
  assert.equal(migrationMissing({ code: "PGRST202", message: "Could not find the function public.cc_ensure_player" }), true);
  assert.equal(migrationMissing({ message: "Not enough gold." }), false);
  assert.equal(banReasonFrom({ message: "This account is banned: Left the gate open." }), "Left the gate open.");
});
