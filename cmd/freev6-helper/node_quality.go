package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/yourname/freev6/internal/mihomo"
	"github.com/yourname/freev6/internal/network"
)

const qualityAge = 30 * 24 * time.Hour
const qualityFresh = 2 * time.Hour

// Only a digest of the active network IDs and gateways is kept on disk.
func qualityNetwork(snapshot network.Snapshot) string {
	var ids []string
	for _, iface := range snapshot.Interfaces {
		if iface.NetworkID == "" || strings.EqualFold(iface.Alias, "FreeV6TUN") {
			continue
		}
		gateways := append(slices.Clone(iface.IPv4DefaultGateways), iface.IPv6DefaultGateways...)
		if len(gateways) == 0 {
			continue
		}
		sort.Strings(gateways)
		ids = append(ids, iface.NetworkID+"|"+strings.Join(gateways, ","))
	}
	if len(ids) == 0 {
		return ""
	}
	sort.Strings(ids)
	sum := sha256.Sum256([]byte(strings.Join(ids, "\n")))
	return hex.EncodeToString(sum[:12])
}

type qualitySample struct {
	Node         string    `json:"node"`
	At           time.Time `json:"at"`
	Kind         string    `json:"kind"`
	Rate         float64   `json:"rate,omitempty"`
	Delay        int       `json:"delay,omitempty"`
	Failed       bool      `json:"failed,omitempty"`
	Source       string    `json:"source"`
	Connections  int       `json:"connections,omitempty"`
	DurationMS   int64     `json:"durationMs,omitempty"`
	SteadyRate   float64   `json:"steadyRate,omitempty"`
	ProbeBytes   int64     `json:"probeBytes,omitempty"`
	Attempts     int       `json:"attempts,omitempty"`
	Timeouts     int       `json:"timeouts,omitempty"`
	Inconclusive bool      `json:"inconclusive,omitempty"`
}
type nodeSwitch struct {
	At     time.Time `json:"at"`
	From   string    `json:"from"`
	To     string    `json:"to"`
	Reason string    `json:"reason"`
}
type groupQuality struct {
	PoolSize  int             `json:"poolSize,omitempty"`
	Pinned    string          `json:"pinned,omitempty"`
	Preferred string          `json:"preferred,omitempty"`
	Switched  time.Time       `json:"switched,omitempty"`
	Reason    string          `json:"reason,omitempty"`
	Samples   []qualitySample `json:"samples"`
	Switches  []nodeSwitch    `json:"switches,omitempty"`
	Updated   time.Time       `json:"updated"`
}
type qualityStore map[string]*groupQuality

func (c *downloadChannel) qualityKey(group string) string {
	prefix := "warp"
	if c.cloud {
		prefix = "campus"
	}
	return c.network + "/" + prefix + "/" + group
}

func (h *helper) qualityPath() string { return filepath.Join(h.root, "state", "node-quality.json") }

func (h *helper) loadQuality() (qualityStore, error) {
	data, err := os.ReadFile(h.qualityPath())
	store := qualityStore{}
	if errors.Is(err, os.ErrNotExist) {
		return store, nil
	}
	if err != nil {
		return nil, err
	}
	if err = json.Unmarshal(data, &store); err != nil || store == nil {
		return nil, errors.New("invalid node quality file")
	}
	for key, g := range store {
		if g == nil {
			delete(store, key)
			continue
		}
		g.trim(time.Now())
	}
	return store, nil
}
func (g *groupQuality) trim(now time.Time) {
	g.Switches = slices.DeleteFunc(g.Switches, func(s nodeSwitch) bool { return s.At.Before(now.Add(-qualityAge)) })
	if len(g.Switches) > 1200 {
		g.Switches = slices.Clone(g.Switches[len(g.Switches)-1200:])
	}
	g.Samples = slices.DeleteFunc(g.Samples, func(s qualitySample) bool { return s.At.Before(now.Add(-qualityAge)) })
	if len(g.Samples) > 1200 {
		g.Samples = slices.Clone(g.Samples[len(g.Samples)-1200:])
	}
}
func (d *nodeDownloads) qualityGroup(c *downloadChannel, group string) *groupQuality {
	key := c.qualityKey(group)
	if d.quality[key] == nil {
		d.quality[key] = &groupQuality{Updated: time.Now().UTC()}
	}
	return d.quality[key]
}
func (h *helper) persistQualityLocked() error {
	d := &h.downloads
	if d.loadErr != nil {
		return d.loadErr
	}
	for len(d.quality) > 32 {
		var oldest string
		for k, g := range d.quality {
			if d.channel != nil && strings.HasPrefix(k, d.channel.network+"/") {
				continue
			}
			if oldest == "" || g.Updated.Before(d.quality[oldest].Updated) {
				oldest = k
			}
		}
		if oldest == "" {
			break
		}
		delete(d.quality, oldest)
	}
	path := h.qualityPath()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".node-quality-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	err = json.NewEncoder(file).Encode(d.quality)
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(file.Name(), path)
}
func (h *helper) commitSamplesLocked(c *downloadChannel, group string, samples []qualitySample) {
	d := &h.downloads
	if d.quality == nil || c.network == "" || len(samples) == 0 {
		return
	}
	g := d.qualityGroup(c, group)
	g.Updated = time.Now().UTC()
	g.Samples = append(g.Samples, samples...)
	g.trim(g.Updated)
	if err := h.persistQualityLocked(); err != nil {
		d.problem = "测速历史写入失败，请检查安装目录是否可写"
	}
}
func (h *helper) saveSampleLocked(c *downloadChannel, group, node string, r downloadResult, err error, source string) {
	h.commitSamplesLocked(c, group, []qualitySample{newSpeedSample(node, source, r, err)})
}

func newSpeedSample(node, source string, r downloadResult, err error) qualitySample {
	return qualitySample{Node: node, At: time.Now().UTC(), Kind: "download", Source: source, Rate: r.BytesPerSecond,
		Failed: err != nil, Connections: max(1, r.Connections), DurationMS: r.DurationMS, SteadyRate: r.SteadyRate}
}

// Writes from an old window or network must never apply to the new connection.
func (h *helper) qualityScope(w http.ResponseWriter, session, group, profile string) (*downloadChannel, bool) {
	d := &h.downloads
	c := d.channel
	if c == nil || session != c.session || (profile != "" && profile != c.network) {
		writeJSON(w, 409, map[string]string{"error": "连接已变更，请重试", "code": "session-changed"})
		return nil, false
	}
	if len(c.members[group]) == 0 {
		writeJSON(w, 400, map[string]string{"error": "无此节点分组"})
		return nil, false
	}
	if c.network == "" || d.loadErr != nil {
		writeJSON(w, 503, map[string]string{"error": d.problem})
		return nil, false
	}
	return c, true
}
func (h *helper) nodeQuality(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var input struct {
		Session, Group, Profile, Mode, Node string
		PoolSize                            *int
	}
	switch r.Method {
	case http.MethodGet:
		input.Session = q.Get("session")
		input.Group = q.Get("group")
	case http.MethodPut:
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&input) != nil || input.Profile == "" {
			writeJSON(w, 400, map[string]string{"error": "选点参数无效"})
			return
		}
	default:
		w.WriteHeader(405)
		return
	}
	d := &h.downloads
	d.mu.Lock()
	defer d.mu.Unlock()
	if r.Method == http.MethodGet && input.Session == "" && d.channel == nil {
		store, err := h.loadQuality()
		if err != nil {
			writeJSON(w, 500, map[string]string{"error": "本机测速历史读取失败"})
			return
		}
		last := &groupQuality{}
		for key, g := range store {
			if strings.HasSuffix(key, "/"+input.Group) && g.Updated.After(last.Updated) {
				last = g
			}
		}
		writeJSON(w, 200, map[string]any{"group": input.Group, "session": "", "quality": last})
		return
	}
	c, ok := h.qualityScope(w, input.Session, input.Group, input.Profile)
	if !ok {
		return
	}
	g := d.qualityGroup(c, input.Group)
	if r.Method == http.MethodPut {
		if input.Mode != "auto" && input.Mode != "fixed" || input.Mode == "fixed" && !slices.Contains(c.members[input.Group], input.Node) {
			writeJSON(w, 400, map[string]string{"error": "请选择当前分组的节点"})
			return
		}
		old := *g
		if input.PoolSize != nil {
			n := *input.PoolSize
			if input.Group != accessGroup || c.pool == nil || input.Mode != "auto" || (n != 2 && n != 4 && n != 8) {
				writeJSON(w, 400, map[string]string{"error": "请选择 2、4 或 8 个并发接入点"})
				return
			}
			g.PoolSize = n
		}
		if input.Mode == "fixed" {
			g.Pinned = input.Node
		} else {
			g.Pinned = ""
		}
		g.Preferred = ""
		g.Reason = ""
		g.Switched = time.Time{}
		g.Updated = time.Now().UTC()
		if d.background && d.cancel != nil {
			d.cancel()
		}
		if err := h.persistQualityLocked(); err != nil {
			*g = old
			writeJSON(w, 500, map[string]string{"error": "选点偏好保存失败"})
			return
		}
		reason := "恢复自动优选，按本网络近期测速选择"
		if g.Pinned != "" {
			reason = "手动固定节点"
		}
		delete(d.rounds, input.Group)
		if err := h.restoreGroupLocked(r.Context(), c, input.Group, g, reason); err != nil {
			d.problem = "选点偏好已保存，核心尚未确认，稍后重试"
			writeJSON(w, 503, map[string]string{"error": d.problem})
			return
		}
		d.problem = ""
	}
	result := map[string]any{"profile": c.network, "group": input.Group, "session": c.session, "quality": g, "problem": d.problem, "latencyGroup": c.latencyGroup}
	if c.pool != nil && input.Group == accessGroup {
		result["poolSize"] = poolSize(g.PoolSize)
		result["candidates"] = c.members[accessGroup]
		if s := c.pool.state; s != nil && s.limit != 0 && g.Pinned == "" {
			var active []string
			for _, node := range s.nodes[:min(s.limit, len(s.nodes))] {
				if !slices.Contains(active, node) {
					active = append(active, node)
				}
			}
			result["activeNodes"] = active
		}
	}
	writeJSON(w, 200, result)
}
func (h *helper) recordNodeDelays(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(405)
		return
	}
	var input struct {
		Session, Group, Profile string
		Delays                  map[string]int
		Timeouts                map[string]int
		Attempts                int
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 256<<10)).Decode(&input) != nil || input.Profile == "" {
		writeJSON(w, 400, map[string]string{"error": "延迟记录无效"})
		return
	}
	d := &h.downloads
	d.mu.Lock()
	defer d.mu.Unlock()
	c, ok := h.qualityScope(w, input.Session, input.Group, input.Profile)
	if !ok {
		return
	}
	var samples []qualitySample
	now := time.Now().UTC()
	for _, node := range c.members[input.Group] {
		delay, ok := input.Delays[node]
		if ok && delay > 0 && delay <= 5000 {
			attempts := max(1, min(3, input.Attempts))
			timeouts := max(0, min(attempts, input.Timeouts[node]))
			if delay >= 5000 {
				timeouts = attempts
			}
			samples = append(samples, qualitySample{Node: node, Kind: "delay", At: now, Delay: delay, Failed: delay >= 5000, Source: "delay", Attempts: attempts, Timeouts: timeouts})
		}
	}
	h.commitSamplesLocked(c, input.Group, samples)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

type qualityProxy struct {
	Now string `json:"now"`
}

func (h *helper) startNodeQuality(c *downloadChannel) {
	d := &h.downloads
	d.mu.Lock()
	d.activateLocked(c)
	d.quality, d.loadErr = h.loadQuality()
	d.problem = ""
	if d.loadErr != nil {
		d.problem = "无法读取本机测速历史，请检查 state/node-quality.json"
	}
	if c.network == "" {
		d.problem = "未识别到上游网络，暂缓保存和选点"
	}
	ctx, cancel := context.WithCancel(context.Background())
	d.stopWorker = cancel
	d.rounds = map[string]*probeRound{}
	c.active = map[string]string{}
	if d.loadErr == nil && c.network != "" {
		h.restoreQualityLocked(ctx, c)
	} else if c.pool != nil {
		_ = c.confirmSelection(ctx, accessGroup, c.pool.group(4))
	} else if c.latencyGroup != "" {
		// Discard a selector restored from another installation/network.
		_ = c.applyPreference(ctx, accessGroup, &groupQuality{})
	}
	d.mu.Unlock()
	go h.qualityWorker(ctx, c)
	if c.pool != nil {
		go h.watchPool(ctx, c)
	}
}
func (h *helper) restoreQualityLocked(ctx context.Context, c *downloadChannel) {
	d := &h.downloads
	for group := range c.members {
		g := d.qualityGroup(c, group)
		if g.Pinned != "" && !slices.Contains(c.members[group], g.Pinned) {
			g.Pinned = ""
			g.Reason = "原固定节点已移除，恢复自动优选"
			if err := h.persistQualityLocked(); err != nil {
				d.problem = "无法保存选点偏好"
			}
		}
		reason := "沿用本网络近期优选结果"
		if g.Pinned != "" {
			reason = "恢复本网络手动固定节点"
		}
		if g.Pinned == "" && g.Preferred == "" {
			reason = "尚无已确认的下载优选，使用可用节点"
		}
		if err := h.restoreGroupLocked(ctx, c, group, g, reason); err != nil {
			d.problem = "核心尚未确认节点选择，将自动重试"
		}
	}
}

func (h *helper) qualityWorker(ctx context.Context, c *downloadChannel) {
	timer := time.NewTimer(20 * time.Second)
	defer timer.Stop()
	var nextProbe time.Time
	round := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		snap, err := network.CaptureSnapshot(ctx, false)
		d := &h.downloads
		d.mu.Lock()
		if d.channel != c || ctx.Err() != nil {
			d.mu.Unlock()
			return
		}
		networkID := ""
		if err == nil {
			networkID = qualityNetwork(snap)
		}
		changed := c.network != networkID
		if changed {
			c.network = networkID
			if c.pool != nil {
				c.pool.state = nil
			}
			d.rounds = map[string]*probeRound{}
			c.active = map[string]string{}
			nextProbe = time.Time{}
			if d.cancel != nil {
				d.cancel()
			}
		}
		ready := networkID != "" && d.loadErr == nil
		if ready {
			d.problem = ""
			h.restoreQualityLocked(ctx, c)
		} else if networkID == "" {
			d.problem = "未识别到上游网络，暂缓保存和选点"
			if changed && c.pool != nil {
				_ = c.confirmSelection(ctx, accessGroup, c.pool.group(4))
			} else if changed && c.latencyGroup != "" {
				_ = c.applyPreference(ctx, accessGroup, &groupQuality{})
			}
		}
		var eligible []string
		if ready && d.cancel == nil && !time.Now().Before(nextProbe) {
			for _, g := range []string{accessGroup, mihomo.ChainGroup} {
				if g == accessGroup && c.pool != nil {
					continue
				}
				if len(c.members[g]) >= 2 && d.qualityGroup(c, g).Pinned == "" {
					eligible = append(eligible, g)
				}
			}
		}
		if len(eligible) > 0 {
			group := eligible[round%len(eligible)]
			round++
			job, stop := context.WithCancel(ctx)
			d.cancel = stop
			d.background = true
			d.mu.Unlock()
			h.probePair(job, c, group, networkID, c.probe, c.checkEndpoint)
			d.mu.Lock()
			if job.Err() == nil {
				nextProbe = time.Now().Add(5 * time.Minute)
			}
			d.cancel = nil
			d.background = false
			stop()
		}
		d.mu.Unlock()
		timer.Reset(time.Minute)
	}
}

func (c *downloadChannel) readGroup(ctx context.Context, group string) (qualityProxy, error) {
	var p qualityProxy
	req, err := http.NewRequestWithContext(ctx, "GET", "http://"+c.controller.String()+"/proxies/"+url.PathEscape(group), nil)
	if err != nil {
		return p, err
	}
	req.Header.Set("Authorization", "Bearer "+c.secret)
	resp, err := localController.Do(req)
	if err != nil {
		return p, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return p, fmt.Errorf("core status %d", resp.StatusCode)
	}
	err = json.NewDecoder(resp.Body).Decode(&p)
	return p, err
}
func (c *downloadChannel) lastingPreference(group string, g *groupQuality) string {
	if slices.Contains(c.members[group], g.Preferred) && (c.active[group] == g.Preferred || time.Since(g.Switched) < qualityFresh || recentNodeStats(g.Samples, g.Preferred, time.Now()).healthyRecent) {
		return g.Preferred
	}
	return ""
}
func (c *downloadChannel) applyPreference(ctx context.Context, group string, g *groupQuality) error {
	want := g.Pinned
	if want == "" {
		want = g.Preferred
	}
	if !slices.Contains(c.members[group], want) {
		want = ""
	}
	if want == "" && group == accessGroup {
		want = c.latencyGroup
	}
	if want == "" {
		return nil
	}
	return c.confirmSelection(ctx, group, want)
}

func (c *downloadChannel) confirmSelection(ctx context.Context, group, want string) error {
	if !c.ownsListeners() {
		return errors.New("core changed")
	}
	p, err := c.readGroup(ctx, group)
	if err != nil {
		return err
	}
	if p.Now == want {
		return nil
	}
	if err = c.selectGroup(ctx, group, want); err != nil {
		return err
	}
	p, err = c.readGroup(ctx, group)
	if err != nil {
		return err
	}
	if p.Now != want {
		return errors.New("selection unconfirmed")
	}
	return nil
}
