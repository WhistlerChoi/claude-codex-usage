import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseAccountInfo, readAccountInfo } from "./account";

const CONFIG = JSON.stringify({
  numStartups: 3,
  oauthAccount: {
    emailAddress: "a@example.com",
    displayName: "a",
    organizationName: "Acme",
    organizationType: "claude_team",
    accountUuid: "acc-1",
    organizationUuid: "org-1",
  },
});

test("parseAccountInfo: reads oauthAccount", () => {
  assert.deepEqual(parseAccountInfo(CONFIG), {
    email: "a@example.com",
    displayName: "a",
    orgName: "Acme",
    orgType: "claude_team",
    accountUuid: "acc-1",
    orgUuid: "org-1",
  });
});

test("parseAccountInfo: null when logged out, malformed, or email missing", () => {
  assert.equal(parseAccountInfo(JSON.stringify({ numStartups: 1 })), null);
  assert.equal(parseAccountInfo("{not json"), null);
  assert.equal(parseAccountInfo(JSON.stringify({ oauthAccount: { organizationName: "x" } })), null);
});

test("readAccountInfo: custom home reads <configDir>/.claude.json, legacy .config.json wins", async () => {
  const dir = await mkdtemp(join(tmpdir(), "pulse-acct-"));
  const home = { configDir: dir, custom: true };
  assert.equal(await readAccountInfo(home), null);
  await writeFile(join(dir, ".claude.json"), CONFIG);
  assert.equal((await readAccountInfo(home))?.email, "a@example.com");
  await writeFile(join(dir, ".config.json"), JSON.stringify({ oauthAccount: { emailAddress: "legacy@example.com" } }));
  assert.equal((await readAccountInfo(home))?.email, "legacy@example.com");
});
