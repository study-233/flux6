package main

import (
	"context"
	"slices"
	"time"
)

type poolCheck struct {
	node, peer, spare string
	baseline          float64
	recovery, explore bool
}

func (s *poolState) nextProbe(now time.Time, traffic map[string]nodeTraffic, candidates []string) poolCheck {
	if now.Before(s.nextCheck) {
		return poolCheck{}
	}
	// Give a held node a finite retry time even if its old connections all closed.
	var due string
	for node, hold := range s.slow {
		if !now.Before(hold.recheck) && (due == "" || hold.recheck.Before(s.slow[due].recheck)) {
			due = node
		}
	}
	if due != "" {
		hold := s.slow[due]
		return poolCheck{node: due, peer: s.nodes[hold.slot], recovery: true, baseline: hold.baseline}
	}
	for _, node := range s.nodes {
		baseline := traffic[node].slowBaseline
		if baseline == 0 || now.Sub(s.lastTest[node]) < 10*time.Second {
			continue
		}
		peer := ""
		for _, n := range s.nodes {
			if n != node && (peer == "" || traffic[n].rate > traffic[peer].rate) {
				peer = n
			}
		}
		if peer == "" {
			for _, n := range candidates {
				if _, held := s.slow[n]; n != node && !held {
					peer = n
					break
				}
			}
		}
		if peer != "" {
			return poolCheck{node: node, peer: peer, baseline: baseline}
		}
	}
	if now.Before(s.nextExplore) {
		return poolCheck{}
	}
	// Cycle through the entire catalog, including unused endpoints and active
	// endpoints without enough successful user traffic to establish a baseline.
	for _, n := range candidates {
		if _, held := s.slow[n]; held {
			continue
		}
		if due == "" || s.lastTest[n].Before(s.lastTest[due]) {
			due = n
		}
	}
	if due == "" {
		return poolCheck{}
	}
	peer := s.nodes[0]
	if peer == due {
		peer = s.nodes[1]
	}
	return poolCheck{node: due, peer: peer, explore: true}
}

func (h *helper) watchPool(ctx context.Context, c *downloadChannel) {
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	d := &h.downloads
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		d.mu.Lock()
		state := c.pool.state
		ready := d.channel == c && state != nil && state.limit != 0 && !state.uncertain && c.network != "" && d.loadErr == nil
		d.mu.Unlock()
		if !ready {
			continue
		}
		rows, err := c.connections(ctx)
		if err != nil {
			continue
		}
		d.mu.Lock()
		if ctx.Err() != nil || d.channel != c || c.pool.state != state {
			d.mu.Unlock()
			continue
		}
		now := time.Now()
		traffic := state.traffic.observe(now, rows, c)
		check := state.nextProbe(now, traffic, c.pool.candidates)
		if check.node == "" || d.cancel != nil {
			d.mu.Unlock()
			continue
		}
		if !check.recovery && slices.Contains(state.nodes, check.node) {
			// Among equally recently checked spares, prefer good historical
			// performance. A dead first spare must not block all other candidates.
			group := d.qualityGroup(c, accessGroup)
			for _, n := range c.pool.ranked(group, now) {
				if _, held := state.slow[n]; held || slices.Contains(state.nodes, n) {
					continue
				}
				if now.Sub(state.lastTest[n]) >= 10*time.Second && recentNodeStats(group.Samples, n, now).healthyRecent {
					check.spare = n
					break
				}
				if check.spare == "" || state.lastTest[n].Before(state.lastTest[check.spare]) {
					check.spare = n
				}
			}
		}
		job, stop := context.WithCancel(ctx)
		d.cancel, d.background = stop, true
		d.mu.Unlock()

		// Keep sampling while a bounded probe is waiting for first bytes. Only
		// the job holding the shared download channel can release it.
		go func() {
			h.checkPoolNode(job, c, state, check, c.probe)
			stop()
			d.mu.Lock()
			d.cancel, d.background = nil, false
			d.mu.Unlock()
		}()
	}
}

func (h *helper) checkPoolNode(ctx context.Context, c *downloadChannel, s *poolState, check poolCheck, probe measureProbe) {
	plan := cloudflarePlan(1, 1<<20, 4*time.Second)
	sample := func(node string) qualitySample {
		started := time.Now()
		result, err := probe(ctx, node, plan)
		if result.Bytes > 0 {
			result.SteadyRate = min(result.SteadyRate, float64(result.Bytes)/time.Since(started).Seconds())
		}
		return newSpeedSample(node, "auto", result, err)
	}
	a := sample(check.node)
	// A responsive idle application and a slow download source can both look
	// like a stalled tunnel. Only act when a controlled download corroborates it.
	slow := a.Failed || a.SteadyRate < .4*check.baseline
	var b, spare qualitySample
	if (check.explore || slow || check.recovery) && check.peer != "" && ctx.Err() == nil {
		b = sample(check.peer)
	}
	if slow && check.spare != "" && ctx.Err() == nil {
		spare = sample(check.spare)
	}
	d := &h.downloads
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.channel != c || c.pool.state != s || ctx.Err() != nil {
		return
	}
	now := time.Now()
	s.nextCheck = now.Add(2 * time.Second)
	s.lastTest[check.node] = now
	if check.explore {
		s.nextExplore = now.Add(5 * time.Minute)
	}
	samples := []qualitySample{a}
	if b.Node != "" {
		a.Inconclusive = a.Failed && b.Failed && (spare.Node == "" || spare.Failed)
		b.Inconclusive = a.Inconclusive
		samples = []qualitySample{a, b}
	}
	if spare.Node != "" {
		samples = append(samples, spare)
		s.lastTest[spare.Node] = now
	}
	h.commitSamplesLocked(c, accessGroup, samples)
	slot := slices.Index(s.nodes, check.node)
	if check.recovery {
		hold, ok := s.slow[check.node]
		if !ok || hold.slot >= len(s.nodes) {
			return
		}
		hold.recheck = now.Add(30 * time.Second)
		s.slow[check.node] = hold
		target := hold.baseline
		if !b.Failed && b.SteadyRate >= usefulDownload {
			target = min(target, b.SteadyRate)
		}
		if !a.Failed && a.SteadyRate >= max(float64(usefulDownload), .6*target) {
			if err := h.replacePoolNode(ctx, c, hold.slot, check.node, "下载复测恢复，重新接收新连接"); err != nil {
				d.problem = "核心未确认接入点恢复"
				return
			}
			delete(s.slow, check.node)
		}
		return
	}
	if slot < 0 {
		// New candidates earn a slot by beating a currently assigned member.
		if check.explore && b.Node != "" && !a.Failed && a.DurationMS >= minimumSampleMS && a.SteadyRate >= usefulDownload && a.SteadyRate > 1.2*b.SteadyRate {
			if i := slices.Index(s.nodes, check.peer); i >= 0 {
				if err := h.replacePoolNode(ctx, c, i, check.node, "候选接入点下载复测领先"); err != nil {
					d.problem = "核心未确认候选接入点"
				}
			}
		}
		return
	}
	if !slow {
		return
	}
	minimum := max(float64(usefulDownload), 2*a.SteadyRate)
	replacement := spare
	if replacement.Node == "" || replacement.Failed || replacement.SteadyRate < minimum {
		replacement = b
	}
	if replacement.Node == "" || replacement.Node == check.node || replacement.Failed || replacement.SteadyRate < minimum {
		return
	}
	for i, n := range s.nodes {
		if n != check.node {
			continue
		}
		if err := h.replacePoolNode(ctx, c, i, replacement.Node, "下载掉速，经复测将新连接转给其他接入点"); err != nil {
			d.problem = "核心未确认掉速切换"
			return
		}
	}
	baseline := check.baseline
	if baseline == 0 {
		baseline = replacement.SteadyRate
	}
	s.slow[check.node] = poolHold{slot: slot, baseline: baseline, recheck: now.Add(10 * time.Second)}
}
