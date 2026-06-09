package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

type currentModel struct {
	ID   string
	Name string
}

// readCurrentModel: the last model from the most recent transcript under ~/.claude/projects.
func readCurrentModel() (*currentModel, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	root := filepath.Join(home, ".claude", "projects")
	dirs, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}

	var best string
	var bestMod int64 = -1
	for _, d := range dirs {
		if !d.IsDir() {
			continue
		}
		sub := filepath.Join(root, d.Name())
		files, err := os.ReadDir(sub)
		if err != nil {
			continue
		}
		for _, f := range files {
			if filepath.Ext(f.Name()) != ".jsonl" {
				continue
			}
			info, err := f.Info()
			if err != nil {
				continue
			}
			if m := info.ModTime().UnixNano(); m > bestMod {
				bestMod = m
				best = filepath.Join(sub, f.Name())
			}
		}
	}
	if best == "" {
		return nil, os.ErrNotExist
	}

	b, err := os.ReadFile(best)
	if err != nil {
		return nil, err
	}
	id := extractLastModel(string(b))
	if id == "" {
		return nil, os.ErrNotExist
	}
	return &currentModel{ID: id, Name: friendlyModelName(id)}, nil
}

func extractLastModel(content string) string {
	lines := strings.Split(content, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line == "" {
			continue
		}
		var o struct {
			Message struct {
				Model string `json:"model"`
			} `json:"message"`
		}
		if json.Unmarshal([]byte(line), &o) == nil && o.Message.Model != "" {
			return o.Message.Model
		}
	}
	return ""
}
