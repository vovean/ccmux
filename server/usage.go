package main

import (
	"strings"
	"time"
)

// UsageWindow is one rate-limit window. Field names must match the Swift client's
// synthesised Codable exactly — it decodes these straight off the wire.
type UsageWindow struct {
	Kind      WindowKind `json:"kind"`
	Label     string     `json:"label"`
	Percent   float64    `json:"percent"`
	ResetsAt  *Time      `json:"resetsAt,omitempty"`
	ModelName *string    `json:"modelName,omitempty"`
}

type WindowKind string

const (
	WindowSession      WindowKind = "session"
	WindowWeeklyAll    WindowKind = "weeklyAll"
	WindowWeeklyScoped WindowKind = "weeklyScoped"
	WindowOther        WindowKind = "other"
)

func (w UsageWindow) Headroom() float64 {
	if 100-w.Percent < 0 {
		return 0
	}
	return 100 - w.Percent
}

func (w UsageWindow) ID() string {
	if w.ModelName != nil && *w.ModelName != "" {
		return string(w.Kind) + "/" + *w.ModelName
	}
	return string(w.Kind) + "/" + w.Label
}

// UsageSnapshot is the server's cached view of one account's windows.
type UsageSnapshot struct {
	Windows           []UsageWindow `json:"windows"`
	FetchedAt         time.Time     `json:"fetchedAt"`
	LastEndpointFetch time.Time     `json:"lastEndpointFetchAt,omitempty"`
	LastError         string        `json:"lastError,omitempty"`
	NextPollAt        time.Time     `json:"nextPollAt,omitempty"`
}

// BindingHeadroom is the window closest to its limit.
func (s UsageSnapshot) BindingHeadroom() (float64, bool) {
	if len(s.Windows) == 0 {
		return 0, false
	}
	lowest := s.Windows[0].Headroom()
	for _, w := range s.Windows[1:] {
		if h := w.Headroom(); h < lowest {
			lowest = h
		}
	}
	return lowest, true
}

// WindowsFromUsageResponse parses GET /api/oauth/usage. Prefers the `limits` array, which
// is the only place per-model weekly windows (e.g. Fable) appear; falls back to the older
// five_hour / seven_day keys when a response carries no `limits`.
func WindowsFromUsageResponse(payload map[string]any) []UsageWindow {
	if limits, ok := payload["limits"].([]any); ok && len(limits) > 0 {
		var parsed []UsageWindow
		for _, entry := range limits {
			limit, ok := entry.(map[string]any)
			if !ok {
				continue
			}
			if w, ok := windowFromLimit(limit); ok {
				parsed = append(parsed, w)
			}
		}
		if len(parsed) > 0 {
			return parsed
		}
	}

	var result []UsageWindow
	if w, ok := legacyWindow(payload["five_hour"], WindowSession, "5-hour"); ok {
		result = append(result, w)
	}
	if w, ok := legacyWindow(payload["seven_day"], WindowWeeklyAll, "Weekly"); ok {
		result = append(result, w)
	}
	return result
}

func windowFromLimit(limit map[string]any) (UsageWindow, bool) {
	percent, ok := limit["percent"].(float64)
	if !ok {
		return UsageWindow{}, false
	}
	resets := parseUsageTime(limit["resets_at"])

	var model string
	if scope, ok := limit["scope"].(map[string]any); ok {
		if m, ok := scope["model"].(map[string]any); ok {
			model, _ = m["display_name"].(string)
		}
	}

	kind, _ := limit["kind"].(string)
	switch kind {
	case "session":
		return UsageWindow{Kind: WindowSession, Label: "5-hour", Percent: percent,
			ResetsAt: resets}, true
	case "weekly_all":
		return UsageWindow{Kind: WindowWeeklyAll, Label: "Weekly", Percent: percent,
			ResetsAt: resets}, true
	case "weekly_scoped":
		if model == "" {
			return UsageWindow{}, false
		}
		return UsageWindow{Kind: WindowWeeklyScoped, Label: "Weekly " + model,
			Percent: percent, ResetsAt: resets, ModelName: &model}, true
	default:
		words := kind
		if words == "" {
			words = "limit"
		}
		words = strings.ReplaceAll(words, "_", " ")
		w := UsageWindow{Kind: WindowOther, Label: upperFirst(words), Percent: percent,
			ResetsAt: resets}
		if model != "" {
			w.ModelName = &model
		}
		return w, true
	}
}

func legacyWindow(raw any, kind WindowKind, label string) (UsageWindow, bool) {
	dict, ok := raw.(map[string]any)
	if !ok {
		return UsageWindow{}, false
	}
	percent, ok := dict["utilization"].(float64)
	if !ok {
		return UsageWindow{}, false
	}
	return UsageWindow{Kind: kind, Label: label, Percent: percent,
		ResetsAt: parseUsageTime(dict["resets_at"])}, true
}

// The usage endpoint sends fractional seconds; the fallback covers a response without
// them.
func parseUsageTime(raw any) *Time {
	text, ok := raw.(string)
	if !ok || text == "" {
		return nil
	}
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
		if parsed, err := time.Parse(layout, text); err == nil {
			return &Time{parsed}
		}
	}
	return nil
}

// Sentence case, not title case: a window label reads as prose next to the hand-written
// ones ("Weekly Fable", "5-hour").
func upperFirst(s string) string {
	if s == "" {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}
