package main

import (
	"fmt"
	"slices"
	"sort"
	"time"
)

const minimumSampleMS = 250

type nodeStats struct {
	floor, nomination float64
	count, failures   int
	delay             int
	lastAuto          time.Time
	healthyRecent     bool
}

// Only duration-qualified single-stream observations enter the decision.
// Older records without timing can still nominate a node for a fresh test.
func recentNodeStats(samples []qualitySample, node string, now time.Time) nodeStats {
	stats := nodeStats{delay: 5001}
	var rates, hints []float64
	for i := len(samples) - 1; i >= 0; i-- {
		s := samples[i]
		if s.Node != node || s.At.After(now) || now.Sub(s.At) > qualityAge {
			continue
		}
		if s.Kind == "delay" {
			if stats.delay == 5001 && now.Sub(s.At) <= qualityFresh {
				stats.delay = s.Delay
			}
			continue
		}
		if s.Kind != "download" || s.Connections > 1 {
			continue
		}
		if s.Source == "auto" && stats.lastAuto.IsZero() {
			stats.lastAuto = s.At
		}
		if !s.Failed && len(hints) < 4 {
			hints = append(hints, s.Rate)
		}
		if now.Sub(s.At) > qualityFresh || stats.count >= 6 || s.Connections != 1 || s.Inconclusive {
			continue
		}
		if s.Failed {
			stats.count++
			stats.failures++
		} else if s.DurationMS >= minimumSampleMS {
			stats.count++
			rates = append(rates, s.SteadyRate)
			stats.healthyRecent = true
		}
	}
	if len(rates) > 0 {
		slices.Sort(rates)
		stats.floor = rates[(len(rates)-1)/4]
	}
	if len(hints) > 0 {
		slices.Sort(hints)
		stats.nomination = hints[(len(hints)-1)/4]
	}
	return stats
}

func (s nodeStats) reliableSpeed() float64 {
	if s.count == 0 {
		return 0
	}
	return s.floor * float64(s.count-s.failures) / float64(s.count)
}

func performanceReason(a, b nodeStats) string {
	if a.count == 0 || !b.healthyRecent || b.failures*4 > b.count ||
		b.reliableSpeed() <= a.reliableSpeed()*1.20 {
		return ""
	}
	if a.count == a.failures {
		return fmt.Sprintf("原节点近期下载 %d 次全部失败，候选稳定下载 %.2f MB/s，已连续两轮复测", a.count, b.floor/1e6)
	}
	return fmt.Sprintf("近期稳定下载 %.2f → %.2f MB/s，下载成功 %d/%d → %d/%d，连续两轮比较领先超过 20%%",
		a.floor/1e6, b.floor/1e6, a.count-a.failures, a.count, b.count-b.failures, b.count)
}

type probeRound struct {
	current, candidate string
	turn, visits, wins int
	last               time.Time
}

func (r *probeRound) choose(nodes []string, current string, samples []qualitySample, now time.Time) string {
	if r.current == current && r.candidate != "" && now.Sub(r.last) <= qualityFresh &&
		(r.visits < 2 || r.visits == 2 && r.wins == 1) && slices.Contains(nodes, r.candidate) {
		return r.candidate
	}
	candidates := slices.DeleteFunc(slices.Clone(nodes), func(n string) bool { return n == current })
	if len(candidates) == 0 {
		return ""
	}
	stats := make(map[string]nodeStats, len(candidates))
	for _, n := range candidates {
		stats[n] = recentNodeStats(samples, n, now)
	}
	explore := r.turn%2 == 1
	sort.SliceStable(candidates, func(i, j int) bool {
		a, b := stats[candidates[i]], stats[candidates[j]]
		if explore && !a.lastAuto.Equal(b.lastAuto) {
			return a.lastAuto.Before(b.lastAuto)
		}
		if a.reliableSpeed() != b.reliableSpeed() {
			return a.reliableSpeed() > b.reliableSpeed()
		}
		if a.nomination != b.nomination {
			return a.nomination > b.nomination
		}
		return a.delay < b.delay
	})
	r.current, r.candidate = current, candidates[0]
	r.visits, r.wins = 0, 0
	r.turn++
	return r.candidate
}
