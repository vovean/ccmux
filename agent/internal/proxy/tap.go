package proxy

import (
	"bytes"
	"encoding/json"
)

// TokenUsage is what one response cost, in tokens.
type TokenUsage struct {
	Input        int `json:"input"`
	Output       int `json:"output"`
	CacheRead    int `json:"cacheRead"`
	CacheWrite5m int `json:"cacheWrite5m"`
	CacheWrite1h int `json:"cacheWrite1h"`
}

func (u TokenUsage) Total() int {
	return u.Input + u.Output + u.CacheRead + u.CacheWrite5m + u.CacheWrite1h
}

func (u TokenUsage) IsZero() bool { return u == TokenUsage{} }

// A single line larger than this is not a usage event, and buffering it would let a
// large non-streaming body sit in memory for nothing.
const maxLineBytes = 256 * 1024

// UsageTap pulls the billed token counts out of a response while it streams past.
//
// The proxy never buffers a response body — it relays chunks as they arrive — so the
// counts have to be picked up in flight. In an SSE stream the input tokens arrive in
// message_start and the final output count in message_delta; a non-streaming reply
// carries one JSON object. Only lines mentioning "usage" are ever parsed, so the cost of
// watching is a substring search per line.
type UsageTap struct {
	partial    []byte
	overflowed bool
	usage      TokenUsage
	// Set when a line was too big to inspect, so the caller can say the cost is unknown
	// rather than reporting a confident zero.
	DroppedOversizedLine bool
}

func (t *UsageTap) Current() TokenUsage { return t.usage }

func (t *UsageTap) Consume(chunk []byte) {
	for len(chunk) > 0 {
		newline := bytes.IndexByte(chunk, '\n')
		if newline < 0 {
			break
		}
		if !t.overflowed {
			t.partial = append(t.partial, chunk[:newline]...)
			t.absorb()
		}
		t.partial = t.partial[:0]
		t.overflowed = false
		chunk = chunk[newline+1:]
	}
	if len(chunk) == 0 {
		return
	}
	if len(t.partial)+len(chunk) > maxLineBytes {
		t.overflowed = true
		t.DroppedOversizedLine = true
		t.partial = t.partial[:0]
		return
	}
	if !t.overflowed {
		t.partial = append(t.partial, chunk...)
	}
}

// Finish absorbs the last line. A non-streaming body has no trailing newline, so it only
// becomes readable once the response ends.
func (t *UsageTap) Finish() {
	if !t.overflowed {
		t.absorb()
	}
	t.partial = t.partial[:0]
	t.overflowed = false
}

func (t *UsageTap) absorb() {
	if len(t.partial) == 0 {
		return
	}
	// Cheap reject before any JSON work: the overwhelming majority of SSE lines are
	// content deltas with no usage in them.
	if !bytes.Contains(t.partial, []byte("usage")) {
		return
	}
	line := t.partial
	if bytes.HasPrefix(line, []byte("data:")) {
		line = line[len("data:"):]
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(line, &object); err != nil {
		return
	}
	// message_start nests it under `message`; message_delta and a plain reply do not.
	holder := object
	if nested, ok := object["message"]; ok {
		var inner map[string]json.RawMessage
		if json.Unmarshal(nested, &inner) == nil {
			holder = inner
		}
	}
	raw, ok := holder["usage"]
	if !ok {
		return
	}
	var counts struct {
		Input         *int `json:"input_tokens"`
		Output        *int `json:"output_tokens"`
		CacheRead     *int `json:"cache_read_input_tokens"`
		CacheCreation *int `json:"cache_creation_input_tokens"`
		Breakdown     *struct {
			Ephemeral5m *int `json:"ephemeral_5m_input_tokens"`
			Ephemeral1h *int `json:"ephemeral_1h_input_tokens"`
		} `json:"cache_creation"`
	}
	if err := json.Unmarshal(raw, &counts); err != nil {
		return
	}
	// Input-side counts appear once, in message_start; output grows across deltas, so
	// the largest value seen is the final one.
	set := func(v *int, into *int) {
		if v != nil && *v > 0 {
			*into = *v
		}
	}
	set(counts.Input, &t.usage.Input)
	set(counts.CacheRead, &t.usage.CacheRead)
	if counts.Breakdown != nil {
		set(counts.Breakdown.Ephemeral5m, &t.usage.CacheWrite5m)
		set(counts.Breakdown.Ephemeral1h, &t.usage.CacheWrite1h)
	} else {
		set(counts.CacheCreation, &t.usage.CacheWrite5m)
	}
	if counts.Output != nil && *counts.Output > t.usage.Output {
		t.usage.Output = *counts.Output
	}
}
