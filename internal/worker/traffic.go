package worker

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"os"
	"strings"
	"sync"
	"time"
)

type trafficBytes struct {
	Upload   uint64 `json:"upload"`
	Download uint64 `json:"download"`
}

func (a trafficBytes) plus(b trafficBytes) (trafficBytes, error) {
	if math.MaxUint64-a.Upload < b.Upload || math.MaxUint64-a.Download < b.Download {
		return trafficBytes{}, errors.New("traffic counter exhausted")
	}
	return trafficBytes{a.Upload + b.Upload, a.Download + b.Download}, nil
}

type trafficReport struct {
	Month   string       `json:"month"`
	Monthly trafficBytes `json:"monthly"`
	Total   trafficBytes `json:"total"`
}

type sessionTraffic struct {
	Schema int                     `json:"schema"`
	Months map[string]trafficBytes `json:"months"`
}

// The worker's existing exclusive data-directory lease also guards these files.
// Each session commits its watermark and monthly deltas in one atomic replacement.
// Historical files are scanned once per worker, even when old observations replay.
type trafficStore struct {
	mu     sync.Mutex
	root   *os.Root
	total  trafficBytes
	months map[string]trafficBytes
}

const sessionFileLimit = 256 * 1024

func readSession(dir *os.Root, name string) (sessionTraffic, trafficBytes, error) {
	empty := sessionTraffic{1, make(map[string]trafficBytes)}
	info, err := dir.Lstat(name)
	if os.IsNotExist(err) {
		return empty, trafficBytes{}, nil
	}
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > sessionFileLimit {
		return empty, trafficBytes{}, errors.New("invalid traffic file")
	}
	f, err := dir.Open(name)
	if err != nil {
		return empty, trafficBytes{}, err
	}
	defer f.Close()
	content, err := io.ReadAll(io.LimitReader(f, sessionFileLimit+1))
	var record sessionTraffic
	if err != nil || len(content) > sessionFileLimit || decodeObject(content, &record) != nil || record.Schema != 1 || record.Months == nil {
		return empty, trafficBytes{}, errors.New("invalid traffic record")
	}
	var watermark trafficBytes
	for month, value := range record.Months {
		if _, err := time.Parse("2006-01", month); err != nil {
			return empty, trafficBytes{}, err
		}
		watermark, err = watermark.plus(value)
		if err != nil {
			return empty, trafficBytes{}, err
		}
	}
	return record, watermark, nil
}

func (s *trafficStore) load(ctx context.Context, dir *os.Root) error {
	if s.months != nil {
		return nil
	}
	entries, err := dir.Open(".")
	if err != nil {
		return err
	}
	defer entries.Close()
	var all trafficBytes
	months := make(map[string]trafficBytes)
	for {
		names, err := entries.Readdirnames(256)
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		for _, name := range names {
			if err := ctx.Err(); err != nil {
				return err
			}
			// Atomic write staging files are never authoritative.
			if strings.HasPrefix(name, ".preferences-") {
				continue
			}
			id, ok := strings.CutSuffix(name, ".json")
			if !ok || !validRevisionUUID(id) || strings.ToLower(id) != id {
				return errors.New("unknown traffic file")
			}
			record, sum, err := readSession(dir, name)
			if err != nil {
				return err
			}
			all, err = all.plus(sum)
			if err != nil {
				return err
			}
			for month, counters := range record.Months {
				months[month], err = months[month].plus(counters)
				if err != nil {
					return err
				}
			}
		}
	}
	s.months, s.total = months, all
	return nil
}

func (s *trafficStore) report(ctx context.Context, now time.Time, id string, observed trafficBytes) (trafficReport, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	month := now.Format("2006-01")
	const folder = "traffic"
	info, err := s.root.Lstat(folder)
	if os.IsNotExist(err) {
		if id == "" {
			return trafficReport{Month: month}, nil
		}
		if err = s.root.Mkdir(folder, 0700); err != nil {
			return trafficReport{}, err
		}
		// Persist the first directory entry before confirming a session observation.
		parent, err := s.root.Open(".")
		if err != nil {
			return trafficReport{}, err
		}
		err = parent.Sync()
		parent.Close()
		if err != nil {
			return trafficReport{}, err
		}
	} else if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return trafficReport{}, errors.New("invalid traffic directory")
	}
	dir, err := s.root.OpenRoot(folder)
	if err != nil {
		return trafficReport{}, err
	}
	defer dir.Close()
	if err := s.load(ctx, dir); err != nil {
		return trafficReport{}, err
	}
	current := trafficReport{month, s.months[month], s.total}
	if id == "" {
		return current, nil
	}
	name := strings.ToLower(id) + ".json"
	record, before, err := readSession(dir, name)
	if err != nil {
		return trafficReport{}, err
	}
	delta := trafficBytes{max(before.Upload, observed.Upload) - before.Upload, max(before.Download, observed.Download) - before.Download}
	if delta == (trafficBytes{}) {
		return current, nil
	}
	current.Total, err = current.Total.plus(delta)
	if err != nil {
		return trafficReport{}, err
	}
	current.Monthly, err = current.Monthly.plus(delta)
	if err != nil {
		return trafficReport{}, err
	}
	record.Months[month], err = record.Months[month].plus(delta)
	if err != nil {
		return trafficReport{}, err
	}
	payload, err := json.Marshal(record)
	if err != nil || len(payload) > sessionFileLimit {
		return trafficReport{}, errors.New("traffic record too large")
	}
	if err := replaceDataFile(ctx, dir, name, payload); err != nil {
		s.months = nil // rename may have succeeded before the directory sync failed
		return trafficReport{}, err
	}
	s.total, s.months[month] = current.Total, current.Monthly
	return current, nil
}

func TrafficHandler(root *os.Root, next Handler) Handler {
	store := &trafficStore{root: root}
	return func(ctx context.Context, method string, params json.RawMessage) (any, error) {
		var id string
		var observed trafficBytes
		switch method {
		case "traffic.get":
			if len(params) != 0 && decodeObject(params, &struct{}{}) != nil {
				return nil, &RPCError{InvalidParams, "invalid traffic request"}
			}
		case "traffic.observe":
			var input struct {
				Session  string  `json:"sessionID"`
				Upload   *uint64 `json:"upload"`
				Download *uint64 `json:"download"`
			}
			if len(params) > 256 || decodeObject(params, &input) != nil || !validRevisionUUID(input.Session) || input.Upload == nil || input.Download == nil {
				return nil, &RPCError{InvalidParams, "invalid traffic observation"}
			}
			id, observed = input.Session, trafficBytes{*input.Upload, *input.Download}
		default:
			return next(ctx, method, params)
		}
		value, err := store.report(ctx, time.Now(), id, observed)
		if err != nil {
			return nil, &RPCError{StorageError, "无法确认流量记录，请检查用户数据目录后重试"}
		}
		return value, nil
	}
}
