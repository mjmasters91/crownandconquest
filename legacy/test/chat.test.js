import assert from "node:assert/strict";
import test from "node:test";
import { chatRateError, cleanChatBody, unreadCount } from "../js/chat.js";

test("chat trims a message and refuses an empty or long one", () => {
  assert.equal(cleanChatBody("  hail   the keep  ").body, "hail the keep");
  assert.ok(cleanChatBody("   ").error);
  assert.ok(cleanChatBody("a".repeat(301)).error);
  assert.equal(cleanChatBody("a".repeat(300)).body.length, 300);
});

test("chat allows one message each three seconds and twenty a minute", () => {
  const now = 60_000;
  const messages = [{ playerKey: "you", createdAt: now - 1000, deleted: false }];
  assert.match(chatRateError(messages, "you", now), /Wait a moment/);
  assert.equal(chatRateError(messages, "you", now + 3000), "");
  const burst = Array.from({ length: 20 }, (_, i) => ({ playerKey: "you", createdAt: now - 4000 - i, deleted: false }));
  assert.match(chatRateError(burst, "you", now), /enough for this minute/);
  assert.equal(unreadCount([{ id: 1, deleted: false }, { id: 2, deleted: true }, { id: 4, deleted: false }], 1), 1);
});
