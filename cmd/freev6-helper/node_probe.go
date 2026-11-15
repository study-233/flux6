package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"slices"
	"time"
)

func (c *downloadChannel) probe(ctx context.Context, node string, plan downloadPlan) (downloadResult, error) {
	return c.measureTarget(ctx, node, plan, nil)
}

// Ask the owned core to test this specific exit against an independent endpoint.
// A controller/transport error is inconclusive, never proof of an outage.
func (c *downloadChannel) checkEndpoint(ctx context.Context, node string) (bool, error) {
	if !c.ownsListeners() {
		return false, errors.New("core changed")
	}
	const target = "https://www.gstatic.com/generate_204"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+c.controller.String()+"/proxies/"+url.PathEscape(node)+"/delay?expected=204&timeout=1500&url="+url.QueryEscape(target), nil)
	if err != nil {
		return false, err
	}
	req.Header.Set("Authorization", "Bearer "+c.secret)
	resp, err := localController.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 503 || resp.StatusCode == 504 {
		return false, nil
	}
	var result struct{ Delay int }
	if resp.StatusCode != 200 || json.NewDecoder(resp.Body).Decode(&result) != nil || result.Delay <= 0 {
		return false, errors.New("health check unavailable")
	}
	return true, nil
}

func (c *downloadChannel) actualNode(ctx context.Context, group string) (string, error) {
	p, err := c.readGroup(ctx, group)
	if err == nil && c.latencyGroup != "" && p.Now == c.latencyGroup {
		p, err = c.readGroup(ctx, c.latencyGroup)
	}
	return p.Now, err
}

func (h *helper) recordSwitchLocked(c *downloadChannel, group, from, to, reason string) {
	if c.active == nil {
		c.active = map[string]string{}
	}
	c.active[group] = to
	if from == "" || from == to || to == "" {
		return
	}
	now := time.Now().UTC()
	g := h.downloads.qualityGroup(c, group)
	g.Switches = append(g.Switches, nodeSwitch{now, from, to, reason})
	g.Reason = from + " → " + to + " · " + reason
	g.Updated = now
	g.trim(now)
}

func (h *helper) restoreGroupLocked(ctx context.Context, c *downloadChannel, group string, g *groupQuality, reason string) error {
	if group == accessGroup && c.pool != nil {
		if g.Pinned == "" {
			reason = "按当前网络设置分配新连接"
		}
		return h.restorePool(ctx, c, g, reason)
	}
	before, err := c.actualNode(ctx, group)
	if err != nil {
		return err
	}
	previous := c.active[group]
	if previous != "" && previous != before {
		h.recordSwitchLocked(c, group, previous, before, "核心按可用性和延迟更新了当前出口")
		if err := h.persistQualityLocked(); err != nil {
			return err
		}
	}
	// Take ownership of the actual cold-start winner. Otherwise URLTest can
	// silently move the exit between observations based solely on latency.
	if g.Pinned == "" && c.lastingPreference(group, g) == "" && len(c.members[group]) > 0 {
		node := before
		if group == accessGroup && c.latencyGroup != "" {
			fallback, err := c.readGroup(ctx, c.latencyGroup)
			if err != nil {
				return err
			}
			node = fallback.Now
		}
		if slices.Contains(c.members[group], node) {
			g.Preferred, g.Switched = node, time.Time{}
			if reason == "沿用本网络近期优选结果" {
				reason = "历史已过期，按当前可用出口开始下载复测"
			}
		}
	}
	if err = c.applyPreference(ctx, group, g); err != nil {
		return err
	}
	after, err := c.actualNode(ctx, group)
	if err != nil {
		return err
	}
	h.recordSwitchLocked(c, group, before, after, reason)
	if before != after {
		return h.persistQualityLocked()
	}
	return nil
}

type measureProbe func(context.Context, string, downloadPlan) (downloadResult, error)
type verifyEndpoint func(context.Context, string) (bool, error)

// Reserve before doing I/O so even a cancelled long test consumes its slot.
// The budget is shared by both groups and survives network/session changes.
func (d *nodeDownloads) reserveExtended(now time.Time) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.extended = slices.DeleteFunc(d.extended, func(at time.Time) bool { return now.Sub(at) >= time.Hour })
	if len(d.extended) >= 3 {
		return false
	}
	d.extended = append(d.extended, now)
	return true
}

func measurePair(ctx context.Context, nodes []string, bytes int64, sample measureProbe) map[string]qualitySample {
	out := make(map[string]qualitySample, 2)
	plan := cloudflarePlan(1, bytes, 4*time.Second)
	for _, node := range nodes {
		if ctx.Err() != nil {
			break
		}
		result, err := sample(ctx, node, plan)
		s := newSpeedSample(node, "auto", result, err)
		s.ProbeBytes = bytes
		out[node] = s
	}
	return out
}

func (h *helper) probePair(ctx context.Context, c *downloadChannel, group, profile string, sample measureProbe, verify verifyEndpoint) {
	current, err := c.actualNode(ctx, group)
	if err != nil || !slices.Contains(c.members[group], current) {
		return
	}
	d := &h.downloads
	d.mu.Lock()
	if d.channel != c || c.network != profile || ctx.Err() != nil {
		d.mu.Unlock()
		return
	}
	g := d.qualityGroup(c, group)
	if g.Pinned != "" {
		d.mu.Unlock()
		return
	}
	r := d.rounds[group]
	if r == nil {
		r = &probeRound{}
		d.rounds[group] = r
	}
	now := time.Now()
	other := r.choose(c.members[group], current, g.Samples, now)
	if other == "" {
		d.mu.Unlock()
		return
	}
	reverse := r.visits%2 == 1
	confirm := r.wins > 0
	d.mu.Unlock()

	order := []string{current, other}
	if reverse {
		slices.Reverse(order)
	}
	pair := measurePair(ctx, order, 1<<20, sample)
	a, b := pair[current], pair[other]
	if ctx.Err() != nil {
		return
	}
	// Give both exits the same larger budget when the short test resolves too
	// quickly or before promoting a challenger. At most 18 MiB per round.
	extended := false
	if !a.Failed && !b.Failed && (a.DurationMS < minimumSampleMS || b.DurationMS < minimumSampleMS || confirm) && d.reserveExtended(time.Now()) {
		extended = true
		slices.Reverse(order)
		pair = measurePair(ctx, order, 8<<20, sample)
		a, b = pair[current], pair[other]
	}
	if ctx.Err() != nil {
		return
	}
	outage := false
	if a.Failed && !b.Failed {
		ok, err := verify(ctx, current)
		if !ok && err == nil {
			backup, err := verify(ctx, other)
			outage = backup && err == nil
		}
	}
	// A simultaneous failure could be the speed server itself. Keep the record
	// for diagnosis but do not lower either node's ranking on that evidence.
	a.Inconclusive = a.Failed && b.Failed
	b.Inconclusive = a.Inconclusive

	d.mu.Lock()
	defer d.mu.Unlock()
	if ctx.Err() != nil || d.channel != c || c.network != profile || g.Pinned != "" || d.rounds[group] != r {
		return
	}
	r.visits++
	r.last = time.Now()
	h.commitSamplesLocked(c, group, []qualitySample{a, b})
	actual, err := c.actualNode(ctx, group)
	if err != nil || actual != current {
		r.wins = 0
		return
	}
	var reason string
	if outage {
		reason = "当前节点下载失败且备用目标复核失败，候选节点下载和备用目标均正常"
	} else {
		if b.Failed || b.SteadyRate <= 0 || b.DurationMS < minimumSampleMS || !a.Failed && a.DurationMS < minimumSampleMS {
			r.wins = 0
			return
		}
		now = time.Now()
		incumbent := recentNodeStats(g.Samples, current, now)
		reason = performanceReason(incumbent, recentNodeStats(g.Samples, other, now))
		if reason == "" || b.SteadyRate <= 1.20*incumbent.reliableSpeed() {
			r.wins = 0
			return
		}
		r.wins++
		if r.wins < 2 || (!extended && !a.Failed) || now.Sub(g.Switched) < 10*time.Minute {
			return
		}
	}
	next := *g
	next.Preferred, next.Switched = other, time.Now().UTC()
	if err := c.applyPreference(ctx, group, &next); err != nil {
		d.problem = "核心未确认自动切换"
		return
	}
	g.Preferred, g.Switched = next.Preferred, next.Switched
	h.recordSwitchLocked(c, group, current, other, reason)
	if err := h.persistQualityLocked(); err != nil {
		d.problem = "自动优选结果保存失败"
	}
}
