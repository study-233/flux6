package core

import (
	"encoding/json"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/metacubex/mihomo/tunnel/statistic"
)

// Both accounting modes are kept so changing "only proxy traffic" never
// subtracts one series from the other or changes historical measurements.
type usageCounters struct {
	All   Traffic
	Proxy Traffic
}

func readUsageCounters() usageCounters {
	return usageCounters{handleGetTotalTraffic(TrafficParams{}), handleGetTotalTraffic(TrafficParams{OnlyProxy: true})}
}

func (c usageCounters) add(other usageCounters) usageCounters {
	return usageCounters{
		Traffic{c.All.Up + other.All.Up, c.All.Down + other.All.Down},
		Traffic{c.Proxy.Up + other.Proxy.Up, c.Proxy.Down + other.Proxy.Down},
	}
}

func (c usageCounters) since(prev usageCounters) usageCounters {
	return usageCounters{
		Traffic{c.All.Up - prev.All.Up, c.All.Down - prev.All.Down},
		Traffic{c.Proxy.Up - prev.Proxy.Up, c.Proxy.Down - prev.Proxy.Down},
	}
}

type usageReport struct {
	Month Traffic `json:"month"`
	Total Traffic `json:"total"`
}

type usageLedger struct {
	mu       sync.Mutex
	path     string
	previous usageCounters
	months   map[string]usageCounters
	pending  map[string]usageCounters
	timer    *time.Timer
}

var trafficUsage usageLedger

func (l *usageLedger) init(home string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	path := filepath.Join(home, "traffic-usage.json")
	if path == l.path {
		return
	}
	l.path = path
	l.months = nil
	l.pending = make(map[string]usageCounters)
	l.previous = readUsageCounters()
}

func (l *usageLedger) observe(now time.Time, counters usageCounters) {
	if l.path == "" {
		return
	}
	delta := counters.since(l.previous)
	l.previous = counters
	if delta != (usageCounters{}) {
		month := now.Format("2006-01")
		l.pending[month] = l.pending[month].add(delta)
	}
}

func (l *usageLedger) load() error {
	if l.months != nil {
		return nil
	}
	if l.path == "" {
		return errors.New("traffic history is not initialized")
	}
	months := make(map[string]usageCounters)
	data, err := os.ReadFile(l.path)
	if err == nil {
		if err := json.Unmarshal(data, &months); err != nil {
			return err
		}
		if months == nil {
			return errors.New("invalid traffic history")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	l.months = months
	return nil
}

func (l *usageLedger) flush() error {
	if len(l.pending) == 0 {
		return nil
	}
	if err := l.load(); err != nil {
		return err
	}
	next := maps.Clone(l.months)
	for month, c := range l.pending {
		next[month] = next[month].add(c)
	}
	file, err := os.CreateTemp(filepath.Dir(l.path), ".traffic-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	err = json.NewEncoder(file).Encode(next)
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = os.Rename(file.Name(), l.path); err != nil {
		return err
	}
	l.months = next
	clear(l.pending)
	return nil
}

func (l *usageLedger) checkpoint() {
	l.observe(time.Now(), readUsageCounters())
	if err := l.flush(); err != nil {
		logError("save traffic usage: %v", err)
	}
}

func (l *usageLedger) resetSession() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.checkpoint()
	statistic.DefaultManager.ResetStatistic()
	l.previous = usageCounters{}
}

func (l *usageLedger) syncWithCore() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !isRunning.Load() {
		if l.timer != nil {
			l.timer.Stop()
			l.timer = nil
		}
		l.checkpoint()
		return
	}
	if l.timer != nil {
		return
	}
	const interval = 15 * time.Second
	var timer *time.Timer
	timer = time.AfterFunc(interval, func() {
		l.mu.Lock()
		defer l.mu.Unlock()
		if l.timer != timer {
			return
		}
		l.checkpoint()
		timer.Reset(interval)
	})
	l.timer = timer
}

func handleGetUsage(params TrafficParams) (usageReport, error) {
	l := &trafficUsage
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	l.observe(now, readUsageCounters())
	return l.report(now.Format("2006-01"), params.OnlyProxy)
}

func (l *usageLedger) report(month string, onlyProxy bool) (usageReport, error) {
	if err := l.load(); err != nil {
		return usageReport{}, err
	}
	var r usageReport
	for _, counts := range []map[string]usageCounters{l.months, l.pending} {
		for key, value := range counts {
			t := value.All
			if onlyProxy {
				t = value.Proxy
			}
			r.Total.Up += t.Up
			r.Total.Down += t.Down
			if key == month {
				r.Month.Up += t.Up
				r.Month.Down += t.Down
			}
		}
	}
	return r, nil
}
