package main

import (
	"encoding/json"
	"testing"
)

// blob: a credentials payload in Claude Code's on-disk shape.
func blob(t *testing.T, accessToken string, expiresAt float64) []byte {
	t.Helper()
	oauth := map[string]any{"accessToken": accessToken, "refreshToken": "r"}
	if expiresAt != 0 {
		oauth["expiresAt"] = expiresAt
	}
	b, err := json.Marshal(map[string]any{"claudeAiOauth": oauth})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}

func TestExtractCreds(t *testing.T) {
	if tok, exp := extractCreds(blob(t, "wrapped", 1234)); tok != "wrapped" || exp != 1234 {
		t.Errorf("wrapper shape: got %q %v", tok, exp)
	}
	flat := []byte(`{"accessToken":"flat","expiresAt":99}`)
	if tok, exp := extractCreds(flat); tok != "flat" || exp != 99 {
		t.Errorf("flat shape: got %q %v", tok, exp)
	}
	if tok, exp := extractCreds([]byte("not json")); tok != "" || exp != 0 {
		t.Errorf("unparseable: got %q %v", tok, exp)
	}
	if tok, _ := extractCreds([]byte(`{"claudeAiOauth":{}}`)); tok != "" {
		t.Errorf("missing token: got %q", tok)
	}
}

func TestPickFreshestToken(t *testing.T) {
	// The reported bug: a months-old credentials file next to a keychain item refreshed today.
	if got := pickFreshestToken([][]byte{blob(t, "dead", 1000), blob(t, "live", 9000)}); got != "live" {
		t.Errorf("fresh keychain should beat stale file: got %q", got)
	}
	// The mirror case must not regress.
	if got := pickFreshestToken([][]byte{blob(t, "live", 9000), blob(t, "dead", 1000)}); got != "live" {
		t.Errorf("fresh file should beat stale keychain: got %q", got)
	}
	// Unusable candidates are skipped, not fatal.
	if got := pickFreshestToken([][]byte{blob(t, "good", 5000), []byte("not json")}); got != "good" {
		t.Errorf("unparseable candidate should be skipped: got %q", got)
	}
	if got := pickFreshestToken([][]byte{blob(t, "only", 5000)}); got != "only" {
		t.Errorf("single candidate: got %q", got)
	}
	// Ties go to the last candidate (callers pass the keychain last).
	if got := pickFreshestToken([][]byte{blob(t, "file", 7000), blob(t, "keychain", 7000)}); got != "keychain" {
		t.Errorf("equal expiry should go to the keychain: got %q", got)
	}
	if got := pickFreshestToken([][]byte{blob(t, "file", 0), blob(t, "keychain", 0)}); got != "keychain" {
		t.Errorf("no expiry anywhere should go to the keychain: got %q", got)
	}
	if got := pickFreshestToken(nil); got != "" {
		t.Errorf("no candidates should yield empty: got %q", got)
	}
}

func TestCombineFingerprints(t *testing.T) {
	// A keychain rotation must change the fingerprint even while the dead file's mtime holds still,
	// otherwise the cache never re-reads and "freshest wins" never gets a second chance.
	if combineFingerprints([]string{"file:100", "keychain:1"}) ==
		combineFingerprints([]string{"file:100", "keychain:2"}) {
		t.Error("keychain rotation must change the combined fingerprint")
	}
	if got := combineFingerprints([]string{"file:100", "keychain:1"}); got != "file:100|keychain:1" {
		t.Errorf("both stores: got %q", got)
	}
	if got := combineFingerprints([]string{"", "keychain:1"}); got != "keychain:1" {
		t.Errorf("keychain only: got %q", got)
	}
	if got := combineFingerprints([]string{"file:100", ""}); got != "file:100" {
		t.Errorf("file only: got %q", got)
	}
	if got := combineFingerprints([]string{"", ""}); got != "" {
		t.Errorf("nothing present should yield empty: got %q", got)
	}
	if got := combineFingerprints(nil); got != "" {
		t.Errorf("nil should yield empty: got %q", got)
	}
}
