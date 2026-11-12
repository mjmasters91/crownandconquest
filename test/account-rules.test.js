import assert from "node:assert/strict";
import test from "node:test";
import { signupFailureMessage, validateEmail, validatePassword, validateUsername } from "../js/account-rules.js";

test("usernames are 3-20 letters, digits, or underscores", () => {
  assert.equal(validateUsername("Ada").username, "Ada");
  assert.equal(validateUsername("vale_warden_01").username, "vale_warden_01");
  assert.ok(validateUsername("ab").error);
  assert.ok(validateUsername("a".repeat(21)).error);
  assert.ok(validateUsername("has space").error);
  assert.ok(validateUsername("bad-name").error);
  assert.ok(validateUsername("name@mail").error);
});

test("emails need a normal address and passwords must match", () => {
  assert.equal(validateEmail("ada@example.com").email, "ada@example.com");
  assert.ok(validateEmail("not-an-email").error);
  assert.equal(validatePassword("secret1", "secret1").password, "secret1");
  assert.equal(validatePassword("short", "short").error, "Password needs at least 6 characters.");
  assert.equal(validatePassword("secret1", "secret2").error, "Passwords do not match.");
});

test("a generic new-user database error means the username is taken", () => {
  assert.equal(signupFailureMessage("Database error saving new user"), "That username is taken.");
  assert.equal(signupFailureMessage("User already registered"), "That email is already registered.");
});
