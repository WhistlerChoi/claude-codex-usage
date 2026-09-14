package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// readCurrentCodexModel reads the last turn_context model from the newest Codex rollout log.
// It is best-effort: Codex usage remains available when no local session log exists.
func readCurrentCodexModel() (*currentModel, error) {
	root := filepath.Join(codexHome(), "sessions")
	var best string
	var bestMod int64 = -1
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || filepath.Ext(path) != ".jsonl" {
			return nil
		}
		if info, e := d.Info(); e == nil && info.ModTime().UnixNano() > bestMod {
			best, bestMod = path, info.ModTime().UnixNano()
		}
		return nil
	})
	if err != nil || best == "" {
		return nil, os.ErrNotExist
	}
	b, err := os.ReadFile(best)
	if err != nil {
		return nil, err
	}
	id := extractLastCodexModel(string(b))
	if id == "" {
		return nil, os.ErrNotExist
	}
	return &currentModel{ID: id, Name: codexModelDisplayName(id)}, nil
}

func extractLastCodexModel(content string) string {
	lines := strings.Split(content, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		var record struct {
			Type    string `json:"type"`
			Payload struct {
				Model string `json:"model"`
			} `json:"payload"`
		}
		if json.Unmarshal([]byte(strings.TrimSpace(lines[i])), &record) == nil && record.Type == "turn_context" && record.Payload.Model != "" {
			return record.Payload.Model
		}
	}
	return ""
}

func codexModelDisplayName(slug string) string {
	b, err := os.ReadFile(filepath.Join(codexHome(), "models_cache.json"))
	if err != nil {
		return slug
	}
	var cache struct {
		Models []struct {
			Slug        string `json:"slug"`
			DisplayName string `json:"display_name"`
		} `json:"models"`
	}
	if json.Unmarshal(b, &cache) != nil {
		return slug
	}
	for _, model := range cache.Models {
		if model.Slug == slug && model.DisplayName != "" {
			return model.DisplayName
		}
	}
	return slug
}
