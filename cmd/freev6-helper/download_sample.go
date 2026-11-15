package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptrace"
	"slices"
	"sync"
	"time"
)

type downloadPlan struct {
	url     string
	streams int
	bytes   int64 // total budget across streams
	timeout time.Duration
}

func cloudflarePlan(streams int, bytes int64, timeout time.Duration) downloadPlan {
	return downloadPlan{fmt.Sprintf("%s?bytes=%d", downloadTarget, bytes/int64(streams)), streams, bytes, timeout}
}

func manualPlan(streams int) downloadPlan {
	return cloudflarePlan(streams, downloadLimit, 10*time.Second)
}

const sampleSlice = 250 * time.Millisecond

type downloadMeter struct {
	sync.Mutex
	first   time.Time
	bytes   int64
	buckets []float64
}

func (m *downloadMeter) start() {
	m.Lock()
	defer m.Unlock()
	if m.first.IsZero() {
		m.first = time.Now()
	}
}

func (m *downloadMeter) Write(p []byte) (int, error) {
	m.Lock()
	defer m.Unlock()
	slot := int(time.Since(m.first) / sampleSlice)
	for len(m.buckets) <= slot {
		m.buckets = append(m.buckets, 0)
	}
	m.buckets[slot] += float64(len(p))
	m.bytes += int64(len(p))
	return len(p), nil
}

func (m *downloadMeter) result(streams int) downloadResult {
	now := time.Now()
	elapsed := now.Sub(m.first)
	average := float64(m.bytes) / elapsed.Seconds()
	full := int(elapsed / sampleSlice)
	steady := average
	if full >= 3 {
		// Include silent intervals. Discard the start-up and incomplete final slice.
		for len(m.buckets) < full {
			m.buckets = append(m.buckets, 0)
		}
		window := m.buckets[1:full]
		slices.Sort(window)
		steady = min(average, window[(len(window)-1)/4]/sampleSlice.Seconds())
	}
	return downloadResult{Bytes: m.bytes, BytesPerSecond: average, MeasuredAt: now.UTC(), Connections: streams,
		DurationMS: elapsed.Milliseconds(), SteadyRate: steady}
}

func readStream(ctx context.Context, client *http.Client, plan downloadPlan, meter *downloadMeter) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, plan.url, nil)
	if err != nil {
		return err
	}
	req = req.WithContext(httptrace.WithClientTrace(req.Context(), &httptrace.ClientTrace{GotFirstResponseByte: meter.start}))
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	limit := plan.bytes / int64(plan.streams)
	if resp.StatusCode != http.StatusOK || resp.ContentLength > limit {
		return errors.New("invalid download response")
	}
	n, err := io.Copy(meter, io.LimitReader(resp.Body, limit+1))
	if n <= 0 || n > limit {
		return errors.New("invalid download sample")
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return nil
	}
	return err
}

func sampleDownload(parent context.Context, client *http.Client, plan downloadPlan) (downloadResult, error) {
	ctx, cancel := context.WithTimeout(parent, plan.timeout)
	defer cancel()
	var meter downloadMeter
	done := make(chan error, plan.streams)
	for range plan.streams {
		go func() { done <- readStream(ctx, client, plan, &meter) }()
	}
	var firstErr error
	for range plan.streams {
		if err := <-done; err != nil && firstErr == nil {
			firstErr = err
			cancel()
		}
	}
	if err := parent.Err(); err != nil {
		return downloadResult{}, err
	}
	if firstErr != nil {
		return downloadResult{}, firstErr
	}
	return meter.result(plan.streams), nil
}
