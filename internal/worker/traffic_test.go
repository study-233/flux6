package worker

import (
	"context"
	"math"
	"strings"
	"testing"
	"time"
)

func TestTrafficReplaysAcrossMonthAndWorkerRestart(t *testing.T) {
	settings, _ := testStore(t)
	store := &trafficStore{root: settings.root}
	january := time.Date(2026, 1, 31, 23, 59, 59, 0, time.UTC)
	february := january.Add(time.Second)
	first := "abcdefab-0000-0000-0000-000000000001"
	second := "abcdefab-0000-0000-0000-000000000002"
	check := func(at time.Time, id string, observed, monthly, total trafficBytes) {
		t.Helper()
		result, err := store.report(context.Background(), at, id, observed)
		if err != nil || result.Month != at.Format("2006-01") || result.Monthly != monthly || result.Total != total {
			t.Fatalf("observation %q %+v: got %+v, %v; want monthly %+v, total %+v", id, observed, result, err, monthly, total)
		}
	}
	check(january, "", trafficBytes{}, trafficBytes{}, trafficBytes{})
	check(january, first, trafficBytes{10, 20}, trafficBytes{10, 20}, trafficBytes{10, 20})
	check(february, strings.ToUpper(first), trafficBytes{10, 20}, trafficBytes{}, trafficBytes{10, 20})
	check(february, second, trafficBytes{5, 6}, trafficBytes{5, 6}, trafficBytes{15, 26})
	store = &trafficStore{root: settings.root}
	check(february, first, trafficBytes{8, 24}, trafficBytes{5, 10}, trafficBytes{15, 30})
	check(february, second, trafficBytes{2, 3}, trafficBytes{5, 10}, trafficBytes{15, 30})
	check(february, first, trafficBytes{11, 18}, trafficBytes{6, 10}, trafficBytes{16, 30})
	store = &trafficStore{root: settings.root}
	check(january, "", trafficBytes{}, trafficBytes{10, 20}, trafficBytes{16, 30})
}

func TestTrafficOverflowPreservesCommittedTotals(t *testing.T) {
	settings, _ := testStore(t)
	store := &trafficStore{root: settings.root}
	ctx := context.Background()
	now := time.Now()
	saved, err := store.report(ctx, now, "abcdefab-0000-0000-0000-000000000001", trafficBytes{math.MaxUint64, 300})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = store.report(ctx, now, "abcdefab-0000-0000-0000-000000000002", trafficBytes{1, 900}); err == nil {
		t.Fatal("accepted overflowing observation")
	}
	restarted := &trafficStore{root: settings.root}
	got, err := restarted.report(ctx, now, "", trafficBytes{})
	if err != nil || got != saved {
		t.Fatalf("got %+v, %v; want %+v", got, err, saved)
	}
}
