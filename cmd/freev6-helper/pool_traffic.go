package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"time"
)

type poolConnection struct {
	ID       string
	Download int64
	Chains   []string
}

func (c *downloadChannel) connections(ctx context.Context) ([]poolConnection, error) {
	if !c.ownsListeners() {
		return nil, errors.New("core changed")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+c.controller.String()+"/connections", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.secret)
	resp, err := localController.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, errors.New("connection statistics unavailable")
	}
	var snapshot struct{ Connections []poolConnection }
	err = json.NewDecoder(resp.Body).Decode(&snapshot)
	return snapshot.Connections, err
}

type flowDownload struct {
	node         string
	bytes        int64
	baseline     float64
	active, dips int
}

type poolTraffic struct {
	at    time.Time
	flows map[string]flowDownload
}

type nodeTraffic struct {
	rate, slowBaseline float64
}

const usefulDownload = 32 * 1024 // bytes/s; ignore control traffic and idle sockets

func (t *poolTraffic) observe(now time.Time, rows []poolConnection, c *downloadChannel) map[string]nodeTraffic {
	elapsed := now.Sub(t.at).Seconds()
	previous := t.flows
	t.at, t.flows = now, make(map[string]flowDownload)
	observed := make(map[string]nodeTraffic)
	for _, conn := range rows {
		// Only attribute the actual leaf of user connections that traversed our
		// pool. Manual test downloads use a separate selector.
		if len(conn.Chains) < 2 || !slices.Contains(conn.Chains, accessGroup) || slices.Contains(conn.Chains, c.group) {
			continue
		}
		node := conn.Chains[0]
		if !slices.Contains(c.pool.candidates, node) || conn.ID == "" {
			continue
		}
		f := previous[conn.ID]
		if f.node != node || conn.Download < f.bytes || elapsed <= 0 || elapsed > 3 {
			t.flows[conn.ID] = flowDownload{node: node, bytes: conn.Download}
			continue
		}
		rate := float64(conn.Download-f.bytes) / elapsed
		f.bytes = conn.Download
		n := observed[node]
		n.rate += rate
		if f.active >= 2 && f.baseline >= usefulDownload && rate < f.baseline*0.3 {
			f.dips++
			if f.dips >= 3 {
				n.slowBaseline = max(n.slowBaseline, f.baseline)
			}
			if f.dips >= 12 {
				f.active, f.dips, f.baseline = 0, 0, 0
			}
		} else {
			f.dips = 0
			if rate >= usefulDownload {
				if f.active == 0 {
					f.baseline = rate
				} else {
					f.baseline = .8*f.baseline + .2*rate
				}
				f.active++
			} else {
				f.active, f.baseline = 0, 0
			}
		}
		observed[node], t.flows[conn.ID] = n, f
	}
	return observed
}
