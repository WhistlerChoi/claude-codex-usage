package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

var errAuth = errors.New("인증이 만료되었습니다. Claude Code에서 재로그인하세요.")

type window struct {
	Utilization float64 `json:"utilization"` // 0~100 (퍼센트)
	ResetsAt    *string `json:"resets_at"`
}

type usageResp struct {
	FiveHour       *window `json:"five_hour"`
	SevenDay       *window `json:"seven_day"`
	SevenDayOpus   *window `json:"seven_day_opus"`
	SevenDaySonnet *window `json:"seven_day_sonnet"`
}

func fetchUsage() (*usageResp, error) {
	token, err := readAccessToken()
	if err != nil {
		return nil, err
	}
	req, _ := http.NewRequest("GET", "https://api.anthropic.com/api/oauth/usage", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")

	client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return nil, errAuth
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("usage API 오류: HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	var u usageResp
	if err := json.Unmarshal(body, &u); err != nil {
		return nil, err
	}
	if u.FiveHour == nil || u.SevenDay == nil {
		return nil, errors.New("usage 응답 형식 오류")
	}
	return &u, nil
}
