// Package app contains business rules shared by the Windows HTTP adapter and
// the macOS stdio worker. It does not perform platform lifecycle operations.
package app

import (
	"encoding/json"
	"errors"
	"strings"

	"github.com/yourname/freev6/internal/mihomo"
)

type Settings struct {
	Mode            string   `json:"mode"`
	CampusCIDRs     []string `json:"campusCidrs"`
	Blacklist       []string `json:"blacklist"`
	DevMode         bool     `json:"devMode"`
	AutoStart       bool     `json:"autoStart"`
	SilentStart     bool     `json:"silentStart"`
	AutoRunProxy    bool     `json:"autoRunProxy"`
	HotkeyEnabled   bool     `json:"hotkeyEnabled"`
	HotspotShare    bool     `json:"hotspotShare"`
	ChainEnabled    bool     `json:"chainEnabled"`
	ChainSourceType string   `json:"chainSourceType"`
	ChainSourceURL  string   `json:"chainSourceUrl"`
	CloudEnabled    bool     `json:"cloudEnabled"`
	CloudSourceURL  string   `json:"cloudSourceUrl"`
	CloudUpdatedAt  string   `json:"cloudUpdatedAt"`
	PortalHost      string   `json:"portalHost"`
}

func DefaultCampusCIDRs() []string { return []string{"edu.cn"} }

func DefaultSettings() Settings {
	return Settings{Mode: mihomo.ModeRule, CampusCIDRs: DefaultCampusCIDRs(), Blacklist: []string{}}
}

// NormalizeSettings validates the common proxy policy without installing login
// items, changing networks or accessing platform credentials.
func NormalizeSettings(current Settings) (Settings, error) {
	if current.Mode == "" {
		current.Mode = mihomo.ModeRule
	}
	if current.Mode != mihomo.ModeRule && current.Mode != mihomo.ModeGlobal && current.Mode != mihomo.ModeDirect {
		return Settings{}, errors.New("mode must be rule, global or direct")
	}
	if current.CampusCIDRs == nil {
		current.CampusCIDRs = DefaultCampusCIDRs()
	}
	entries := make([]string, 0, len(current.CampusCIDRs))
	for _, entry := range current.CampusCIDRs {
		if err := mihomo.ValidateCampusTarget(entry); err != nil {
			return Settings{}, err
		}
		entries = append(entries, strings.ToLower(strings.TrimSpace(entry)))
	}
	current.CampusCIDRs = entries
	blacklist := make([]string, 0, len(current.Blacklist))
	for _, entry := range current.Blacklist {
		if err := mihomo.ValidateDomain(entry); err != nil {
			return Settings{}, err
		}
		blacklist = append(blacklist, strings.ToLower(strings.TrimSpace(entry)))
	}
	current.Blacklist = blacklist
	return current, nil
}

// DecodeLegacySettingsPUT preserves the existing Windows HTTP contract. Basic
// fields use replacement semantics; newer fields preserve their stored value
// when omitted. In particular, an omitted chain/cloud flag must not disable a
// separately imported profile. Null blacklist also retains the stored list.
func DecodeLegacySettingsPUT(body []byte, persisted Settings) (Settings, error) {
	var current Settings
	if err := json.Unmarshal(body, &current); err != nil {
		return Settings{}, errors.New("invalid JSON")
	}
	var keys map[string]json.RawMessage
	_ = json.Unmarshal(body, &keys)
	has := func(key string) bool { _, ok := keys[key]; return ok }
	if current.Blacklist == nil {
		current.Blacklist = persisted.Blacklist
	}
	if !has("autoRunProxy") {
		current.AutoRunProxy = persisted.AutoRunProxy
	}
	if !has("hotkeyEnabled") {
		current.HotkeyEnabled = persisted.HotkeyEnabled
	}
	if !has("hotspotShare") {
		current.HotspotShare = persisted.HotspotShare
	}
	if !has("chainEnabled") {
		current.ChainEnabled = persisted.ChainEnabled
	}
	if !has("chainSourceType") {
		current.ChainSourceType = persisted.ChainSourceType
	}
	if !has("chainSourceUrl") {
		current.ChainSourceURL = persisted.ChainSourceURL
	}
	if !has("cloudEnabled") {
		current.CloudEnabled = persisted.CloudEnabled
	}
	if !has("cloudSourceUrl") {
		current.CloudSourceURL = persisted.CloudSourceURL
	}
	if !has("cloudUpdatedAt") {
		current.CloudUpdatedAt = persisted.CloudUpdatedAt
	}
	if !has("portalHost") {
		current.PortalHost = persisted.PortalHost
	}
	return NormalizeSettings(current)
}

// ProxyPreferences is the editable Mac policy. Profile URLs and platform
// startup options have separate owners and are deliberately absent here.
type ProxyPreferences struct {
	Mode        string   `json:"mode"`
	CampusCIDRs []string `json:"campusCidrs"`
	Blacklist   []string `json:"blacklist"`
	DevMode     bool     `json:"devMode"`
}

func DefaultProxyPreferences() ProxyPreferences { return PreferencesFrom(DefaultSettings()) }

func PreferencesFrom(s Settings) ProxyPreferences {
	return ProxyPreferences{s.Mode, s.CampusCIDRs, s.Blacklist, s.DevMode}
}

func PatchProxyPreferences(current ProxyPreferences, changes json.RawMessage) (ProxyPreferences, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(changes, &fields); err != nil || fields == nil {
		return current, errors.New("changes must be an object")
	}
	for key, value := range fields {
		switch key {
		case "mode", "campusCidrs", "blacklist", "devMode":
		default:
			return current, errors.New("unsupported preference field")
		}
		if string(value) == "null" {
			return current, errors.New("preference values cannot be null")
		}
	}
	if err := json.Unmarshal(changes, &current); err != nil {
		return current, errors.New("invalid preference value")
	}
	if len(current.CampusCIDRs) > 2048 || len(current.Blacklist) > 2048 {
		return current, errors.New("too many preference entries")
	}
	for _, entries := range [][]string{current.CampusCIDRs, current.Blacklist} {
		for _, entry := range entries {
			if len(entry) > 1024 {
				return current, errors.New("preference entry too long")
			}
		}
	}
	s, err := NormalizeSettings(Settings{Mode: current.Mode, CampusCIDRs: current.CampusCIDRs, Blacklist: current.Blacklist, DevMode: current.DevMode})
	if err != nil {
		return current, err
	}
	return PreferencesFrom(s), nil
}
