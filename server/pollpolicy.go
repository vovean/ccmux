package main

import (
	"math"
	"math/rand"
	"time"
)

// Cadence for GET /api/oauth/usage, ported from Sources/CCMuxCore/Usage/PollPolicy.swift.
//
// The endpoint budgets roughly 28-30 requests per rolling hour per access token, and
// capacity only returns as old requests age out — a burst saturates the token for up to
// an hour, so pausing does not buy headroom back. These constants target ~20
// requests/hour and leave room for manual refreshes. Measured by claude-swap
// (poll_policy.py, 2026-07-11); re-measure before loosening any of them.
const (
	pollMinInterval      = 180 * time.Second
	pollUrgentInterval   = 60 * time.Second
	pollActiveMax        = 300 * time.Second
	pollIdleMax          = 600 * time.Second
	pollMovementDelta    = 1.0
	pollJitterFraction   = 0.1
	pollRateLimitBackoff = 300 * time.Second
	pollEscalationMargin = 15.0
)

type PollPlan struct {
	Interval   time.Duration
	NextPollAt time.Time
}

// PlanPoll decides when to look again.
func PlanPoll(isInUse bool, previous *UsageSnapshot, current UsageSnapshot,
	threshold float64, rateLimited bool, now time.Time) PollPlan {
	if rateLimited {
		return PollPlan{
			Interval:   pollRateLimitBackoff,
			NextPollAt: now.Add(jitter(pollRateLimitBackoff)),
		}
	}

	moved := movement(previous, current) >= pollMovementDelta
	headroom := 100.0
	if h, ok := current.BindingHeadroom(); ok {
		headroom = h
	}
	nearThreshold := headroom <= threshold+pollEscalationMargin

	var interval time.Duration
	switch {
	case isInUse && nearThreshold && moved:
		interval = pollUrgentInterval
	case isInUse && moved:
		interval = pollMinInterval
	case isInUse:
		interval = pollActiveMax
	case moved:
		interval = pollActiveMax
	default:
		interval = pollIdleMax
	}

	// A window resetting soon is worth one prompt poll just after it turns over.
	var soonest time.Time
	for _, w := range current.Windows {
		if w.ResetsAt == nil || !w.ResetsAt.After(now) {
			continue
		}
		if soonest.IsZero() || w.ResetsAt.Before(soonest) {
			soonest = w.ResetsAt.Time
		}
	}
	if !soonest.IsZero() {
		untilReset := soonest.Sub(now) + time.Minute
		if untilReset < interval {
			interval = untilReset
			if interval < pollUrgentInterval {
				interval = pollUrgentInterval
			}
		}
	}

	return PollPlan{Interval: interval, NextPollAt: now.Add(jitter(interval))}
}

func movement(previous *UsageSnapshot, current UsageSnapshot) float64 {
	if previous == nil {
		return math.Inf(1)
	}
	var delta float64
	for _, window := range current.Windows {
		var before float64
		for _, old := range previous.Windows {
			if old.ID() == window.ID() {
				before = old.Percent
				break
			}
		}
		if d := math.Abs(window.Percent - before); d > delta {
			delta = d
		}
	}
	return delta
}

func jitter(interval time.Duration) time.Duration {
	spread := float64(interval) * pollJitterFraction
	return time.Duration(float64(interval) + (rand.Float64()*2-1)*spread)
}
