import { test } from "node:test";
import assert from "node:assert/strict";
import { homedir } from "node:os";
import { join } from "node:path";
import { claudeHome, keychainServiceName, globalConfigCandidates, credentialsFilePath, projectsDir } from "./claudeHome";

test("claudeHome: unset or empty CLAUDE_CONFIG_DIR means ~/.claude", () => {
  assert.deepEqual(claudeHome({}), { configDir: join(homedir(), ".claude"), custom: false });
  assert.deepEqual(claudeHome({ CLAUDE_CONFIG_DIR: "" }), { configDir: join(homedir(), ".claude"), custom: false });
  assert.deepEqual(claudeHome({ CLAUDE_CONFIG_DIR: "/x/.claude-work" }), { configDir: "/x/.claude-work", custom: true });
});

test("keychainServiceName: default home has no suffix", () => {
  assert.equal(keychainServiceName(claudeHome({})), "Claude Code-credentials");
});

test("keychainServiceName: CLAUDE_CONFIG_DIR home gets sha256 suffix of the raw string", () => {
  // Vectors match Claude Code's own naming; a trailing slash is a different item.
  assert.equal(keychainServiceName({ configDir: "/Users/test/.claude-work", custom: true }), "Claude Code-credentials-03abf0ee");
  assert.equal(keychainServiceName({ configDir: "/Users/test/.claude-work/", custom: true }), "Claude Code-credentials-8bd6f0f5");
});

test("paths follow the home", () => {
  const custom = { configDir: "/x/.claude-work", custom: true };
  assert.equal(credentialsFilePath(custom), "/x/.claude-work/.credentials.json");
  assert.equal(projectsDir(custom), "/x/.claude-work/projects");
  assert.deepEqual(globalConfigCandidates(custom), ["/x/.claude-work/.config.json", "/x/.claude-work/.claude.json"]);
  const def = claudeHome({});
  assert.deepEqual(globalConfigCandidates(def), [join(homedir(), ".claude", ".config.json"), join(homedir(), ".claude.json")]);
});
