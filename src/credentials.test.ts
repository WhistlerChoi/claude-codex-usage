import { test } from "node:test";
import assert from "node:assert/strict";
import {
  extractAccessToken,
  CredentialsError,
  parseCredentials,
  pickFreshestToken,
  combineFingerprints,
} from "./credentials";

/** A credentials blob in Claude Code's on-disk shape. */
function blob(accessToken: string, expiresAt?: number): string {
  return JSON.stringify({
    claudeAiOauth: { accessToken, refreshToken: "r", ...(expiresAt != null ? { expiresAt } : {}) },
  });
}

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

test("parseCredentials returns the token and expiry, null instead of throwing", () => {
  assert.deepEqual(parseCredentials(blob("t", 1234)), { accessToken: "t", expiresAt: 1234 });
  assert.deepEqual(parseCredentials(blob("t")), { accessToken: "t", expiresAt: undefined });
  assert.equal(parseCredentials("not json"), null);
  assert.equal(parseCredentials(JSON.stringify({ claudeAiOauth: {} })), null);
  assert.equal(parseCredentials(JSON.stringify({ accessToken: "" })), null);
});

test("pickFreshestToken: fresh keychain beats stale file (the reported bug)", () => {
  // A months-old credentials file next to a keychain item Claude Code refreshed today.
  assert.equal(pickFreshestToken([blob("dead", 1_000), blob("live", 9_000)]), "live");
});

test("pickFreshestToken: fresh file beats stale keychain (mirror case must not regress)", () => {
  assert.equal(pickFreshestToken([blob("live", 9_000), blob("dead", 1_000)]), "live");
});

test("pickFreshestToken: skips missing and unparseable stores", () => {
  assert.equal(pickFreshestToken([null, blob("only", 5_000)]), "only");
  assert.equal(pickFreshestToken([blob("good", 5_000), "not json"]), "good");
  assert.equal(pickFreshestToken([blob("good", 5_000), null]), "good");
});

test("pickFreshestToken: ties go to the last candidate (the keychain)", () => {
  assert.equal(pickFreshestToken([blob("file", 7_000), blob("keychain", 7_000)]), "keychain");
  assert.equal(pickFreshestToken([blob("file"), blob("keychain")]), "keychain");
});

test("pickFreshestToken: nothing usable -> null", () => {
  assert.equal(pickFreshestToken([]), null);
  assert.equal(pickFreshestToken([null, null]), null);
  assert.equal(pickFreshestToken(["not json"]), null);
});

test("combineFingerprints: every present store contributes", () => {
  // A keychain rotation must change the fingerprint even while the dead file's mtime holds still,
  // otherwise the cache never re-reads and "freshest wins" never gets a second chance.
  assert.notEqual(
    combineFingerprints(["file:100", "keychain:1"]),
    combineFingerprints(["file:100", "keychain:2"])
  );
  assert.equal(combineFingerprints(["file:100", "keychain:1"]), "file:100|keychain:1");
  assert.equal(combineFingerprints([null, "keychain:1"]), "keychain:1");
  assert.equal(combineFingerprints(["file:100", null]), "file:100");
  assert.equal(combineFingerprints([null, null]), null);
  assert.equal(combineFingerprints([]), null);
});
