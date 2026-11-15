package main

import (
	"encoding/json"
	"net/http/httptest"
	"net/url"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/yourname/freev6/internal/network"
)

func TestStableDownloadRanking(t *testing.T) {
	now := time.Now()
	var samples []qualitySample
	add := func(n string, rate float64) {
		samples = append(samples, qualitySample{Node: n, At: now, Kind: "download", Source: "auto", Rate: rate, SteadyRate: rate, DurationMS: 850, Connections: 1})
	}
	for _, rate := range []float64{2, 18, 2, 18, 2, 18} {
		add("A", rate)
		add("B", 10)
	}
	stats := func(n string) nodeStats { return recentNodeStats(samples, n, now) }
	if stats("A").floor != 2 || stats("B").floor != 10 || performanceReason(stats("A"), stats("B")) == "" {
		t.Fatal("ignored recurring dips")
	}
	// An older version, four streams, and a sub-second burst cannot buy priority.
	for _, s := range []qualitySample{
		{Node: "C", Kind: "download", Source: "auto", Rate: 80},
		{Node: "C", Kind: "download", Connections: 4, DurationMS: 1000, SteadyRate: 40},
		{Node: "C", Kind: "download", Connections: 1, DurationMS: 100, SteadyRate: 200},
	} {
		s.At = now
		samples = append(samples, s)
	}
	if stats("C").count != 0 || performanceReason(stats("A"), stats("C")) != "" {
		t.Fatal("incomparable samples entered ranking")
	}
	for i := 0; i < 3; i++ {
		samples = append(samples, qualitySample{At: now, Node: "B", Kind: "download", Connections: 1, Failed: true})
	}
	if performanceReason(stats("A"), stats("B")) != "" {
		t.Fatal("unreliable challenger promoted")
	}
	add("D", 2.39)
	if performanceReason(stats("A"), stats("D")) != "" {
		t.Fatal("switched for a marginal advantage")
	}
}

func TestDownloadCandidateExploration(t *testing.T) {
	now := time.Now()
	history := []qualitySample{{At: now, Kind: "download", Node: "fast", Rate: 1e7, Source: "manual"}, {At: now, Kind: "delay", Node: "low-latency", Delay: 10}}
	r := probeRound{}
	nodes := []string{"current", "low-latency", "fast"}
	if r.choose(nodes, "current", history, now) != "fast" {
		t.Fatal("history ignored")
	}
	r.visits = 2
	history = append(history, qualitySample{At: now, Node: "fast", Kind: "download", Source: "auto", Rate: 1e7})
	if r.choose(nodes, "current", history, now) != "low-latency" {
		t.Fatal("starved unmeasured exit")
	}
}

func TestQualityHistoryAcrossRestartAndNetwork(t *testing.T) {
	h := &helper{root: t.TempDir()}
	d := &h.downloads
	c := &downloadChannel{session: "one", network: "dorm", members: map[string][]string{accessGroup: {"A"}}}
	d.activate(c)
	d.quality = qualityStore{}
	w := httptest.NewRecorder()
	body := `{"session":"one","group":"♻️ 自动选择","profile":"dorm","delays":{"A":24,"unknown":1}}`
	h.recordNodeDelays(w, httptest.NewRequest("POST", "/", strings.NewReader(body)))
	if w.Code != 200 {
		t.Fatal(w.Body)
	}
	h.saveSampleLocked(c, accessGroup, "A", downloadResult{BytesPerSecond: 5000000}, nil, "manual")
	c.network = "other"
	if len(d.qualityGroup(c, accessGroup).Samples) != 0 {
		t.Fatal("network histories mixed")
	}
	w = httptest.NewRecorder()
	h.recordNodeDelays(w, httptest.NewRequest("POST", "/", strings.NewReader(body)))
	if w.Code != 409 {
		t.Fatal("accepted late sample")
	}
	h = &helper{root: h.root}
	w = httptest.NewRecorder()
	h.nodeQuality(w, httptest.NewRequest("GET", "/?group="+url.QueryEscape(accessGroup), nil))
	var response struct{ Quality groupQuality }
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &response) != nil || len(response.Quality.Samples) != 2 {
		t.Fatalf("offline history %v", w.Body)
	}
	if s := response.Quality.Samples; s[0].Delay != 24 || s[1].Rate != 5000000 {
		t.Fatal(s)
	}
	if err := os.WriteFile(h.qualityPath(), []byte("{"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := h.loadQuality(); err == nil {
		t.Fatal("accepted corrupt history")
	}
}
func TestQualityNetworkFingerprint(t *testing.T) {
	s := network.Snapshot{Interfaces: []network.InterfaceSnapshot{{NetworkID: "wifi-a", IPv4DefaultGateways: []string{"192.0.2.1"}}, {Alias: "FreeV6TUN", NetworkID: "tunnel", IPv4DefaultGateways: []string{"127.0.0.1"}}}}
	id := qualityNetwork(s)
	slices.Reverse(s.Interfaces)
	if id == "" || qualityNetwork(s) != id || strings.Contains(id, "wifi") {
		t.Fatal("unstable network fingerprint")
	}
	s.Interfaces[1].NetworkID = "wifi-b"
	if id == qualityNetwork(s) {
		t.Fatal("distinct Windows networks share samples")
	}
}

func TestExtendedProbeBudget(t *testing.T) {
	var d nodeDownloads
	now := time.Now()
	for i := 0; i < 3; i++ {
		if !d.reserveExtended(now.Add(time.Duration(i) * time.Minute)) {
			t.Fatal("early exhaustion")
		}
	}
	if d.reserveExtended(now.Add(time.Hour-time.Second)) || !d.reserveExtended(now.Add(time.Hour)) || d.reserveExtended(now.Add(time.Hour)) {
		t.Fatal("rolling probe budget incorrect")
	}
}
