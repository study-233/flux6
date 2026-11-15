package core

import (
	"io"
	"net"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func TestProxyOnlyTrafficLeavesOutADirectProxyOfAnyName(t *testing.T) {
	direct := outbound.NewDirectWithOption(outbound.DirectOption{Name: "直连"})
	reject := outbound.NewRejectWithOption(outbound.RejectOption{Name: "HK"})
	tunnel.UpdateProxies(map[string]constant.Proxy{
		"直连": adapter.NewProxy(direct),
		"HK": adapter.NewProxy(reject),
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	for _, test := range []struct {
		outbound constant.ProxyAdapter
		proxied  int64
	}{
		{direct, 0},
		{reject, 5},
	} {
		statistic.DefaultManager.ResetStatistic()
		local, remote := net.Pipe()
		go func() { _, _ = io.Copy(io.Discard, remote) }()
		tracker := statistic.NewTCPTracker(
			outbound.NewConn(local, test.outbound),
			statistic.DefaultManager,
			&constant.Metadata{},
			nil,
			0,
			0,
			true,
		)

		if _, err := tracker.Write([]byte("hello")); err != nil {
			t.Fatalf("write through %s: %v", test.outbound.Name(), err)
		}
		_ = tracker.Close()
		_ = remote.Close()

		all, _ := statistic.DefaultManager.TotalTraffic(false)
		proxied, _ := statistic.DefaultManager.TotalTraffic(true)
		if all != 5 || proxied != test.proxied {
			t.Errorf("%s: total %d, proxied %d; want 5 and %d", test.outbound.Name(), all, proxied, test.proxied)
		}
	}
	statistic.DefaultManager.ResetStatistic()
}

func TestUsageSurvivesSessionCounterReset(t *testing.T) {
	statistic.DefaultManager.ResetStatistic()
	var ledger usageLedger
	ledger.init(t.TempDir())
	statistic.DefaultManager.PushDownloaded(true, 30)
	statistic.DefaultManager.PushDownloaded(false, 70)
	ledger.resetSession()
	statistic.DefaultManager.PushUploaded(false, 12)
	t.Cleanup(statistic.DefaultManager.ResetStatistic)
	now := time.Now()
	ledger.observe(now, readUsageCounters())
	for _, tc := range []struct {
		onlyProxy bool
		want      Traffic
	}{
		{false, Traffic{12, 100}}, {true, Traffic{12, 70}},
	} {
		got, err := ledger.report(now.Format("2006-01"), tc.onlyProxy)
		if err != nil || got.Total != tc.want {
			t.Fatalf("proxy only %t after reset: got %+v (%v), want %+v", tc.onlyProxy, got, err, tc.want)
		}
	}
}
