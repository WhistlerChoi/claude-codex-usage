import { test } from "node:test";
import assert from "node:assert/strict";
import { extractAccessToken, CredentialsError } from "./credentials";

test("extracts from claudeAiOauth wrapper", () => {
  const raw = JSON.stringify({ claudeAiOauth: { accessToken: "tok-123", refreshToken: "r" } });
  assert.equal(extractAccessToken(raw), "tok-123");
});

test("extracts from flat shape", () => {
  assert.equal(extractAccessToken(JSON.stringify({ accessToken: "tok-flat" })), "tok-flat");
});

test("tolerates surrounding whitespace", () => {
  assert.equal(extractAccessToken('  {"accessToken":"x"}\n'), "x");
});

test("throws on invalid json", () => {
  assert.throws(() => extractAccessToken("not json"), CredentialsError);
});

test("throws when token missing", () => {
  assert.throws(() => extractAccessToken(JSON.stringify({ claudeAiOauth: {} })), CredentialsError);
});

test("throws when token empty", () => {
  assert.throws(() => extractAccessToken(JSON.stringify({ accessToken: "" })), CredentialsError);
});
