package worker

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"

	"github.com/yourname/freev6/internal/app"
)

const maxSettingsBytes = 256 * 1024
const settingsFile = "proxy-preferences.json"

type SettingsSnapshot struct {
	SchemaVersion int                  `json:"schemaVersion"`
	Revision      uint64               `json:"revision"`
	Settings      app.ProxyPreferences `json:"settings"`
}

type SettingsStore struct {
	mu   sync.Mutex
	root *os.Root
}

func NewSettingsStore(root *os.Root) *SettingsStore { return &SettingsStore{root: root} }

func (s *SettingsStore) Get() (SettingsSnapshot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.read()
}

func (s *SettingsStore) read() (SettingsSnapshot, error) {
	defaults := SettingsSnapshot{SchemaVersion: 1, Settings: app.DefaultProxyPreferences()}
	info, err := s.root.Lstat(settingsFile)
	if os.IsNotExist(err) {
		return defaults, nil
	}
	if err != nil {
		return defaults, err
	}
	if !info.Mode().IsRegular() || info.Size() > maxSettingsBytes {
		return defaults, errors.New("invalid settings file")
	}
	f, err := s.root.Open(settingsFile)
	if err != nil {
		return defaults, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxSettingsBytes+1))
	if err != nil || len(data) > maxSettingsBytes {
		return defaults, errors.New("cannot read settings")
	}
	var snapshot SettingsSnapshot
	if err := decodeObject(data, &snapshot); err != nil {
		return defaults, errors.New("settings file is damaged; original retained")
	}
	if snapshot.SchemaVersion != 1 || snapshot.Revision == 0 {
		return defaults, errors.New("unsupported settings schema; original retained")
	}
	policy, err := json.Marshal(snapshot.Settings)
	if err != nil {
		return defaults, err
	}
	snapshot.Settings, err = app.PatchProxyPreferences(app.DefaultProxyPreferences(), policy)
	if err != nil {
		return defaults, errors.New("settings file contains invalid values; original retained")
	}
	return snapshot, nil
}

func (s *SettingsStore) Patch(ctx context.Context, revision uint64, changes json.RawMessage) (SettingsSnapshot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	current, err := s.read()
	if err != nil {
		return current, &RPCError{Code: StorageError, Message: err.Error()}
	}
	if current.Revision != revision {
		return current, &RPCError{Code: Conflict, Message: "settings changed; reload before saving"}
	}
	next, err := app.PatchProxyPreferences(current.Settings, changes)
	if err != nil {
		return current, &RPCError{Code: InvalidParams, Message: err.Error()}
	}
	if current.Revision == ^uint64(0) {
		return current, &RPCError{Code: StorageError, Message: "settings revision exhausted"}
	}
	current.Settings = next
	current.Revision++
	data, err := json.MarshalIndent(current, "", "  ")
	if err != nil {
		return current, err
	}
	if len(data)+1 > maxSettingsBytes {
		return current, &RPCError{Code: InvalidParams, Message: "settings are too large"}
	}
	if err := ctx.Err(); err != nil {
		return current, err
	}
	if err := s.replace(ctx, append(data, '\n')); err != nil {
		return current, &RPCError{Code: StorageError, Message: "cannot save settings; reload to confirm state"}
	}
	return current, nil
}

func (s *SettingsStore) replace(ctx context.Context, data []byte) error {
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return err
	}
	name := ".preferences-" + hex.EncodeToString(nonce[:])
	f, err := s.root.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	defer s.root.Remove(name)
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	// Cancellation after this commit cannot roll back a successful write.
	if err := s.root.Rename(name, settingsFile); err != nil {
		return err
	}
	directory, err := s.root.Open(".")
	if err != nil {
		return err
	}
	defer directory.Close()
	if err := directory.Sync(); err != nil {
		return fmt.Errorf("sync settings directory: %w", err)
	}
	return nil
}
