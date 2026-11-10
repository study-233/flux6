package mobileapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/yourname/freev6/internal/app"
	"github.com/yourname/freev6/internal/warp"
)

func RegisterWarp(ctx context.Context) (string, error) {
	client := warp.NewClient(&http.Client{Timeout: 20 * time.Second})
	device, err := client.Register(ctx, "FreeV6 Android")
	if err != nil {
		return "", err
	}
	if err := warp.ValidateDevice(device); err != nil {
		return "", err
	}
	data, err := json.Marshal(device)
	return string(data), err
}

func RenderWarpProfile(credentials string, campusTargets []string) (string, error) {
	if len(credentials) > 32*1024 || len(campusTargets) > 128 {
		return "", errors.New("invalid FreeV6 configuration size")
	}
	var device warp.Device
	if json.Unmarshal([]byte(credentials), &device) != nil || warp.ValidateDevice(device) != nil {
		return "", errors.New("invalid saved WARP credentials")
	}
	preferences := app.DefaultProxyPreferences()
	preferences.CampusCIDRs = campusTargets
	configuration, err := app.PrepareWarpConfiguration(preferences, warp.TunnelCredentials{
		PrivateKey: device.PrivateKey, PeerPublicKey: device.PeerPublicKey,
		IPv4: device.IPv4, IPv6: device.IPv6,
	})
	if err != nil {
		return "", err
	}
	encoded, err := json.Marshal(configuration)
	if err != nil {
		return "", err
	}
	var profile map[string]any
	if err := json.Unmarshal(encoded, &profile); err != nil {
		return "", err
	}
	profile["ipv6"] = true
	profile["dns"] = map[string]any{
		"enable": true, "ipv6": true, "enhanced-mode": "fake-ip",
		"fake-ip-range": "198.18.0.1/16", "fake-ip-filter": []string{"*.lan", "*.local"},
		"nameserver": []string{"system", "https://[2606:4700:4700::1111]/dns-query"},
	}
	data, err := json.Marshal(profile)
	return string(data), err
}
