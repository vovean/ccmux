package proxy

import (
	"strings"
	"testing"
)

var transcript = []string{
	"event: message_start\n",
	`data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":7,` +
		`"cache_read_input_tokens":12000,"cache_creation":{"ephemeral_5m_input_tokens":22028,` +
		`"ephemeral_1h_input_tokens":0},"output_tokens":1}}}` + "\n\n",
	"event: content_block_delta\n",
	`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}` + "\n\n",
	"event: message_delta\n",
	`data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":214}}` + "\n\n",
	"event: message_stop\n",
	`data: {"type":"message_stop"}` + "\n\n",
}

func TestTheTapReadsAStreamWhateverTheChunkBoundaries(t *testing.T) {
	whole := strings.Join(transcript, "")
	want := TokenUsage{Input: 7, Output: 214, CacheRead: 12000, CacheWrite5m: 22028}
	// A chunk boundary anywhere, including mid-number, must not change the answer.
	for _, size := range []int{1, 7, 64, 512, len(whole)} {
		tap := &UsageTap{}
		for start := 0; start < len(whole); start += size {
			end := min(start+size, len(whole))
			tap.Consume([]byte(whole[start:end]))
		}
		tap.Finish()
		if tap.Current() != want {
			t.Errorf("chunk size %d: got %+v, want %+v", size, tap.Current(), want)
		}
		if tap.DroppedOversizedLine {
			t.Errorf("chunk size %d: reported a dropped line", size)
		}
	}
}

// A non-streaming reply is one JSON object with no trailing newline.
func TestTheTapReadsANonStreamingReply(t *testing.T) {
	tap := &UsageTap{}
	tap.Consume([]byte(`{"id":"msg_1","usage":{"input_tokens":5,"output_tokens":9}}`))
	tap.Finish()
	if got := tap.Current(); got.Input != 5 || got.Output != 9 {
		t.Errorf("got %+v", got)
	}
}

// The older shape, before cache writes were split by lifetime.
func TestAFlatCacheCreationCountsAsTheFiveMinuteWrite(t *testing.T) {
	tap := &UsageTap{}
	tap.Consume([]byte(`{"usage":{"cache_creation_input_tokens":40,"output_tokens":1}}`))
	tap.Finish()
	if got := tap.Current(); got.CacheWrite5m != 40 || got.CacheWrite1h != 0 {
		t.Errorf("got %+v", got)
	}
}

// Output grows across deltas, so the largest value seen is the final one; the input-side
// counts appear once and must not be clobbered by a later event that omits them.
func TestLaterEventsNeverLowerTheCounts(t *testing.T) {
	tap := &UsageTap{}
	tap.Consume([]byte(`data: {"message":{"usage":{"input_tokens":11,"output_tokens":1}}}` + "\n"))
	tap.Consume([]byte(`data: {"usage":{"output_tokens":90}}` + "\n"))
	tap.Consume([]byte(`data: {"usage":{"output_tokens":42}}` + "\n"))
	tap.Finish()
	if got := tap.Current(); got.Input != 11 || got.Output != 90 {
		t.Errorf("got %+v", got)
	}
}

// A line too large to inspect is dropped rather than buffered, and the caller is told so
// it can record the cost as unknown instead of a confident zero.
func TestAnOversizedLineIsDroppedAndDeclared(t *testing.T) {
	tap := &UsageTap{}
	tap.Consume([]byte(`data: {"usage":{"padding":"` + strings.Repeat("x", maxLineBytes+16)))
	tap.Consume([]byte("\"}}\n"))
	tap.Consume([]byte(`data: {"usage":{"output_tokens":5}}` + "\n"))
	tap.Finish()
	if !tap.DroppedOversizedLine {
		t.Error("an oversized line was not declared")
	}
	// The line after the oversized one is still read.
	if tap.Current().Output != 5 {
		t.Errorf("the tap did not recover: %+v", tap.Current())
	}
}

func TestLinesWithoutUsageCostNothingAndChangeNothing(t *testing.T) {
	tap := &UsageTap{}
	tap.Consume([]byte("event: content_block_delta\n"))
	tap.Consume([]byte(`data: {"delta":{"text":"hello"}}` + "\n"))
	tap.Finish()
	if !tap.Current().IsZero() {
		t.Errorf("got %+v", tap.Current())
	}
}
