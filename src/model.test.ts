import { test } from "node:test";
import assert from "node:assert/strict";
import { friendlyModelName, extractLastModel } from "./model";

test("friendlyModelName: opus 4.8", () => {
  assert.equal(friendlyModelName("claude-opus-4-8"), "Opus 4.8");
});

test("friendlyModelName: sonnet 4.6", () => {
  assert.equal(friendlyModelName("claude-sonnet-4-6"), "Sonnet 4.6");
});

test("friendlyModelName: haiku with date suffix", () => {
  assert.equal(friendlyModelName("claude-haiku-4-5-20251001"), "Haiku 4.5");
});

test("friendlyModelName: old 3.5 format", () => {
  assert.equal(friendlyModelName("claude-3-5-sonnet-20241022"), "Sonnet 3.5");
});

test("friendlyModelName: unknown shape returns raw", () => {
  assert.equal(friendlyModelName("gpt-foo"), "gpt-foo");
});

test("friendlyModelName: empty", () => {
  assert.equal(friendlyModelName(""), "Unknown");
});

test("extractLastModel: picks last model scanning from end", () => {
  const content = [
    JSON.stringify({ type: "user", message: { role: "user" } }),
    JSON.stringify({ type: "assistant", message: { model: "claude-sonnet-4-6" } }),
    JSON.stringify({ type: "assistant", message: { model: "claude-opus-4-8" } }),
    JSON.stringify({ type: "user", message: { role: "user" } }),
    "",
  ].join("\n");
  assert.equal(extractLastModel(content), "claude-opus-4-8");
});

test("extractLastModel: tolerates malformed lines", () => {
  const content = ["not json", JSON.stringify({ message: { model: "claude-opus-4-8" } }), "{bad"].join("\n");
  assert.equal(extractLastModel(content), "claude-opus-4-8");
});

test("extractLastModel: none returns null", () => {
  assert.equal(extractLastModel('{"type":"user"}\n{"message":{}}'), null);
});
