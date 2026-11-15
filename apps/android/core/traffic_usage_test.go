package core

import (
	"path/filepath"
	"testing"
	"time"
)

func TestUsageAcrossMonthsResetAndRelaunch(t *testing.T) {
	path := filepath.Join(t.TempDir(), "traffic-usage.json")
	ledger := &usageLedger{path: path, pending: make(map[string]usageCounters)}
	jan := time.Date(2026, 1, 31, 23, 59, 57, 0, time.Local)
	feb := jan.Add(time.Minute)
	first := usageCounters{Traffic{30, 100}, Traffic{10, 50}}
	ledger.observe(jan, first)
	ledger.observe(jan, first)
	ledger.observe(feb, usageCounters{Traffic{32, 105}, Traffic{11, 53}})
	if err := ledger.flush(); err != nil {
		t.Fatal(err)
	}
	// The next core session starts its counters at zero; the saved months remain.
	ledger = &usageLedger{path: path, pending: make(map[string]usageCounters)}
	ledger.observe(feb, usageCounters{Traffic{4, 12}, Traffic{2, 8}})
	check := func(proxy bool, want usageReport) {
		t.Helper()
		got, err := ledger.report("2026-02", proxy)
		if err != nil || got != want {
			t.Fatalf("only proxy %t: got %+v, %v; want %+v", proxy, got, err, want)
		}
	}
	check(false, usageReport{Traffic{6, 17}, Traffic{36, 117}})
	check(true, usageReport{Traffic{3, 11}, Traffic{13, 61}})
	if err := ledger.flush(); err != nil {
		t.Fatal(err)
	}
	ledger = &usageLedger{path: path}
	check(false, usageReport{Traffic{6, 17}, Traffic{36, 117}})
}
