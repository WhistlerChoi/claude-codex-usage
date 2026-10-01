package main

import (
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

// accountInfo: the logged-in account, from oauthAccount in Claude Code's global config.
type accountInfo struct {
	Email       string
	DisplayName string
	OrgName     string
	OrgType     string // e.g. "claude_team", "claude_enterprise", "claude_max"
	AccountUUID string
	OrgUUID     string
}

// parseAccountInfo: nil when the config holds no logged-in account. Pure.
func parseAccountInfo(b []byte) *accountInfo {
	var c struct {
		OauthAccount *struct {
			EmailAddress     string `json:"emailAddress"`
			DisplayName      string `json:"displayName"`
			OrganizationName string `json:"organizationName"`
			OrganizationType string `json:"organizationType"`
			AccountUUID      string `json:"accountUuid"`
			OrganizationUUID string `json:"organizationUuid"`
		} `json:"oauthAccount"`
	}
	if json.Unmarshal(b, &c) != nil || c.OauthAccount == nil || c.OauthAccount.EmailAddress == "" {
		return nil
	}
	oa := c.OauthAccount
	return &accountInfo{oa.EmailAddress, oa.DisplayName, oa.OrganizationName, oa.OrganizationType, oa.AccountUUID, oa.OrganizationUUID}
}

type accountCacheEntry struct {
	modTime time.Time
	size    int64
	info    *accountInfo
}

// The global config is large and rewritten constantly by Claude Code; re-parse only on change.
var (
	accountCacheMu sync.Mutex
	accountCache   = map[string]accountCacheEntry{}
)

// readAccountInfo: best-effort — any failure (no file, unreadable, logged out) is nil, never an error.
func readAccountInfo(h claudeHomeDir) *accountInfo {
	for _, path := range h.globalConfigCandidates() {
		st, err := os.Stat(path)
		if err != nil {
			continue // absent → next candidate
		}
		accountCacheMu.Lock()
		hit, ok := accountCache[path]
		accountCacheMu.Unlock()
		if ok && hit.modTime.Equal(st.ModTime()) && hit.size == st.Size() {
			return hit.info
		}
		var info *accountInfo
		if b, err := os.ReadFile(path); err == nil {
			info = parseAccountInfo(b)
		}
		accountCacheMu.Lock()
		accountCache[path] = accountCacheEntry{st.ModTime(), st.Size(), info}
		accountCacheMu.Unlock()
		return info
	}
	return nil
}

var maxTierRe = regexp.MustCompile(`max_(\d+)x`)

// planLabel: plan name from the credentials' subscriptionType / rateLimitTier. Empty when neither
// is known. e.g. ("max", "default_claude_max_20x") → "Max 20x", ("team", "default_claude_max_5x")
// → "Team (Max 5x)". Mirrors src/format.ts.
func planLabel(subscriptionType, rateLimitTier string) string {
	tier := ""
	if m := maxTierRe.FindStringSubmatch(rateLimitTier); m != nil {
		tier = "Max " + m[1] + "x"
	}
	switch subscriptionType {
	case "":
		return tier
	case "max":
		if tier != "" {
			return tier
		}
		return "Max"
	}
	names := map[string]string{"pro": "Pro", "team": "Team", "enterprise": "Enterprise"}
	base, ok := names[subscriptionType]
	if !ok {
		base = strings.ToUpper(subscriptionType[:1]) + subscriptionType[1:]
	}
	if tier != "" {
		return base + " (" + tier + ")"
	}
	return base
}

var orgKindRe = regexp.MustCompile(`team|enterprise`)

// accountLine: "email · plan · org". The org name is shown only for team / enterprise orgs — a
// personal org is just named after the email. Empty when nothing is known. Mirrors src/format.ts.
func accountLine(info *accountInfo, plan string) string {
	parts := []string{}
	if info != nil && info.Email != "" {
		parts = append(parts, info.Email)
	}
	if plan != "" {
		parts = append(parts, plan)
	}
	if info != nil && info.OrgName != "" && orgKindRe.MatchString(info.OrgType) {
		parts = append(parts, info.OrgName)
	}
	return strings.Join(parts, " · ")
}
