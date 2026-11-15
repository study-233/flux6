package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"sync/atomic"
	"testing"
	"time"
)

func TestPoolTrafficIgnoresIdleFinishedAndTestConnections(t *testing.T) {
	c := &downloadChannel{group: "measure", pool: newAccessPool("fixture", []string{"A", "B"}, nil)}
	rows := []poolConnection{
		{ID: "ongoing", Chains: []string{"A", accessGroup}},
		{ID: "healthy", Chains: []string{"B", accessGroup}},
		{ID: "idle", Chains: []string{"A", accessGroup}},
		{ID: "probe", Chains: []string{"A", "measure"}},
	}
	var meter poolTraffic
	at := time.Now()
	for i := 0; i <= 6; i++ {
		if i <= 3 {
			rows[0].Download += 500000
		}
		rows[1].Download += 350000
		rows[3].Download += 4000000
		observed := meter.observe(at.Add(time.Duration(i)*time.Second), rows, c)
		if i > 0 && observed["B"].rate != 350000 {
			t.Fatal(observed)
		}
		if i < 6 && observed["A"].slowBaseline != 0 {
			t.Fatal("early signal", observed)
		}
		if i == 6 && (observed["A"].slowBaseline != 500000 || observed["A"].rate != 0) {
			t.Fatal("missing signal or test traffic leaked", observed)
		}
	}
	if rows := meter.observe(at.Add(7*time.Second), rows[1:], c); rows["A"].slowBaseline != 0 {
		t.Fatal("closed connection penalized node")
	}
	if len(meter.flows) != 2 {
		t.Fatal("retained finished or test connections")
	}
}

func testActivePool(t *testing.T, c *downloadChannel, dir string, names []string, server *httptest.Server, hits []atomic.Int32) {
	t.Helper()
	ctx := context.Background()
	c.network = "fixture"
	h := &helper{root: dir}
	h.downloads.activate(c)
	h.downloads.quality = qualityStore{}
	h.restoreQualityLocked(ctx, c)
	g := h.downloads.qualityGroup(c, accessGroup)
	p := c.pool
	userProxy := &url.URL{Scheme: "http", Host: c.address, User: url.UserPassword(downloadUser, c.password)}
	tr := &http.Transport{Proxy: http.ProxyURL(userProxy), DisableKeepAlives: true, TLSClientConfig: server.Client().Transport.(*http.Transport).TLSClientConfig}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: 2 * time.Second}
	assertRoutes := func(expected []string) {
		t.Helper()
		for i := range hits {
			hits[i].Store(0)
		}
		for range len(expected) * 2 {
			resp, err := client.Get(server.URL)
			if err != nil {
				t.Fatal(err)
			}
			resp.Body.Close()
		}
		for i, n := range names {
			want := int32(0)
			if slices.Contains(expected, n) {
				want = 2
			}
			if hits[i].Load() != want {
				t.Fatalf("%s got %d requests want %d; pool %v", n, hits[i].Load(), want, expected)
			}
		}
	}
	writePolicy := func(mode, node string, size int) int {
		t.Helper()
		input := map[string]any{"session": c.session, "profile": c.network, "group": accessGroup, "mode": mode, "node": node}
		if size != 0 {
			input["poolSize"] = size
		}
		b, _ := json.Marshal(input)
		w := httptest.NewRecorder()
		h.nodeQuality(w, httptest.NewRequest("PUT", "/", bytes.NewReader(b)))
		return w.Code
	}
	assertRoutes(names[:4])
	// The controller must expose the actual leaf node on an open production
	// route, otherwise passive measurements cannot be attributed to a slot.
	openCtx, closeStream := context.WithCancel(ctx)
	req, err := http.NewRequestWithContext(openCtx, http.MethodGet, server.URL+"/slow", nil)
	if err != nil {
		t.Fatal(err)
	}
	response, err := client.Do(req)
	if err != nil {
		closeStream()
		t.Fatal(err)
	}
	rows, err := c.connections(ctx)
	closeStream()
	response.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, r := range rows {
		if len(r.Chains) > 0 && slices.Contains(names[:4], r.Chains[0]) && slices.Contains(r.Chains, accessGroup) {
			found = true
		}
	}
	if !found {
		t.Fatal("core did not report a real leaf for the active access group", rows)
	}
	for _, size := range []int{8, 2, 4} {
		if writePolicy("auto", "", size) != 200 {
			t.Fatal("resize", size)
		}
		assertRoutes(names[:size])
	}
	if writePolicy("auto", "", 3) != 400 {
		t.Fatal("accepted invalid size")
	}
	probe := func(_ context.Context, node string, _ downloadPlan) (downloadResult, error) {
		rate := float64(600000)
		if node == names[0] {
			rate = 10000
		}
		return downloadResult{BytesPerSecond: rate, SteadyRate: rate, DurationMS: 900, Connections: 1}, nil
	}
	state := p.state
	check := poolCheck{node: names[0], peer: names[1], spare: names[27], baseline: 500000}
	fast := func(ctx context.Context, _ string, p downloadPlan) (downloadResult, error) {
		return probe(ctx, names[1], p)
	}
	h.checkPoolNode(ctx, c, state, check, fast)
	assertRoutes(names[:4])
	h.checkPoolNode(ctx, c, state, check, func(ctx context.Context, _ string, p downloadPlan) (downloadResult, error) {
		return probe(ctx, names[0], p)
	})
	assertRoutes(names[:4])
	h.checkPoolNode(ctx, c, state, check, probe)
	assertRoutes([]string{names[27], names[1], names[2], names[3]})
	hold, ok := state.slow[names[0]]
	if !ok {
		t.Fatal("missing recovery")
	}
	recheck := state.nextProbe(hold.recheck, nil, p.candidates)
	if !recheck.recovery || recheck.node != names[0] {
		t.Fatal(recheck)
	}
	h.checkPoolNode(ctx, c, state, recheck, probe)
	assertRoutes(state.nodes)
	if _, ok := state.slow[names[0]]; !ok {
		t.Fatal("readmitted slow node")
	}
	h.checkPoolNode(ctx, c, state, recheck, fast)
	assertRoutes(names[:4])
	// A single shared bottleneck among the selected slots must not hide a
	// healthy spare outside the pool.
	h.checkPoolNode(ctx, c, state, check, func(ctx context.Context, node string, p downloadPlan) (downloadResult, error) {
		if node == check.peer {
			node = check.node
		}
		return probe(ctx, node, p)
	})
	assertRoutes([]string{names[27], names[1], names[2], names[3]})
	if writePolicy("auto", "", 8) != 200 || writePolicy("fixed", names[26], 0) != 200 {
		t.Fatal("pin")
	}
	h.checkPoolNode(ctx, c, state, check, probe)
	assertRoutes([]string{names[26]})
	stored, err := h.loadQuality()
	if err != nil || stored[c.qualityKey(accessGroup)].PoolSize != 8 || g.Pinned != names[26] {
		t.Fatal("lost preferences", err)
	}
	h.downloads.quality = stored
	h.restoreQualityLocked(ctx, c)
	assertRoutes([]string{names[26]})
	if writePolicy("auto", "", 0) != 200 || len(p.state.nodes) != 8 {
		t.Fatal("pin to auto")
	}
}
