package main

import (
	"context"
	"fmt"
	"slices"
	"sort"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// A slot is a core selector. Changing its member changes only future dials,
// including UDP associations. The round-robin groups share the first N slots.
type accessPool struct {
	id         string
	candidates []string
	state      *poolState
}

type poolState struct {
	nodes       []string // confirmed slots, in core order
	limit       int
	uncertain   bool
	traffic     poolTraffic
	slow        map[string]poolHold
	lastTest    map[string]time.Time
	nextCheck   time.Time
	nextExplore time.Time
}

type poolHold struct {
	slot     int
	baseline float64
	recheck  time.Time
}

func newAccessPool(id string, names []string, servers map[string]string) *accessPool {
	// Interleave ports on different ingress addresses for an unmeasured network.
	byHost := make(map[string][]string)
	var hosts []string
	for _, name := range names {
		host := servers[name]
		if _, ok := byHost[host]; !ok {
			hosts = append(hosts, host)
		}
		byHost[host] = append(byHost[host], name)
	}
	p := &accessPool{id: id}
	for port := 0; len(p.candidates) < len(names); port++ {
		for _, host := range hosts {
			if port < len(byHost[host]) {
				p.candidates = append(p.candidates, byHost[host][port])
			}
		}
	}
	return p
}

func (p *accessPool) slot(i int) string     { return fmt.Sprintf("__Flux6_Slot_%s_%d", p.id, i) }
func (p *accessPool) group(size int) string { return fmt.Sprintf("__Flux6_Pool_%s_%d", p.id, size) }

func (p *accessPool) addGroups(groups *yaml.Node, healthURL string) error {
	appendGroup := func(fields map[string]any) error {
		var node yaml.Node
		if err := node.Encode(fields); err != nil {
			return err
		}
		groups.Content = append(groups.Content, &node)
		return nil
	}
	var slots []string
	for i := range min(8, len(p.candidates)) {
		name := p.slot(i)
		slots = append(slots, name)
		if err := appendGroup(map[string]any{"name": name, "type": "select", "hidden": true,
			"proxies": p.candidates, "default-selected": p.candidates[i]}); err != nil {
			return err
		}
	}
	for _, n := range []int{2, 4, 8} {
		if err := appendGroup(map[string]any{"name": p.group(n), "type": "load-balance", "strategy": "round-robin",
			"hidden": true, "proxies": slots[:min(n, len(slots))], "url": healthURL, "interval": 30, "lazy": true}); err != nil {
			return err
		}
	}
	return nil
}

func poolSize(n int) int {
	if n == 2 || n == 8 {
		return n
	}
	return 4
}

func (p *accessPool) ranked(g *groupQuality, now time.Time) []string {
	names := slices.Clone(p.candidates)
	scores := make(map[string]float64, len(names))
	for _, n := range names {
		scores[n] = recentNodeStats(g.Samples, n, now).reliableSpeed()
	}
	sort.SliceStable(names, func(i, j int) bool { return scores[names[i]] > scores[names[j]] })
	return names
}

// Caller holds downloads.mu. Keep the actual applied prefix on partial failure
// so the next restore can retry without advertising an unconfirmed pool.
func (h *helper) restorePool(ctx context.Context, c *downloadChannel, g *groupQuality, reason string) error {
	p := c.pool
	before := c.active[accessGroup]
	if g.Pinned != "" {
		p.state = nil
		if err := c.applyPreference(ctx, accessGroup, g); err != nil {
			return err
		}
	} else {
		size := poolSize(g.PoolSize)
		if p.state == nil {
			p.state = &poolState{slow: make(map[string]poolHold), lastTest: make(map[string]time.Time)}
		}
		s := p.state
		n := min(size, len(p.candidates))
		// A controller timeout can arrive after a successful PUT. Reconcile
		// every affected slot before relying on its last confirmed membership.
		if s.uncertain {
			for i, node := range s.nodes[:min(n, len(s.nodes))] {
				if err := c.confirmSelection(ctx, p.slot(i), node); err != nil {
					return err
				}
			}
		}
		// Program additional slots before allowing the core to route through them.
		if len(s.nodes) < n {
			for _, node := range p.ranked(g, time.Now()) {
				if slices.Contains(s.nodes, node) {
					continue
				}
				if _, held := s.slow[node]; held {
					continue
				}
				if err := c.confirmSelection(ctx, p.slot(len(s.nodes)), node); err != nil {
					return err
				}
				s.nodes = append(s.nodes, node)
				if len(s.nodes) == n {
					break
				}
			}
		}
		if len(s.nodes) < n {
			return fmt.Errorf("可用接入点不足")
		}
		if err := c.confirmSelection(ctx, accessGroup, p.group(size)); err != nil {
			return err
		}
		s.nodes = s.nodes[:n]
		s.limit = size
		s.uncertain = false
		for node, hold := range s.slow {
			if hold.slot >= n {
				delete(s.slow, node)
			}
		}
	}
	after := g.Pinned
	if after == "" {
		after = strings.Join(p.state.nodes, "、")
	}
	h.recordSwitchLocked(c, accessGroup, before, after, reason)
	if before != "" && before != after {
		return h.persistQualityLocked()
	}
	return nil
}

func (h *helper) replacePoolNode(ctx context.Context, c *downloadChannel, slot int, node, reason string) error {
	s := c.pool.state
	old := s.nodes[slot]
	if err := c.confirmSelection(ctx, c.pool.slot(slot), node); err != nil {
		s.uncertain = true
		return err
	}
	s.nodes[slot] = node
	h.recordSwitchLocked(c, accessGroup, old, node, reason)
	c.active[accessGroup] = strings.Join(s.nodes, "、")
	// Routing has already changed. A history write failure must not prevent
	// the caller from scheduling recovery for this confirmed switch.
	if err := h.persistQualityLocked(); err != nil {
		h.downloads.problem = "接入点已切换，切换记录保存失败"
	}
	return nil
}
