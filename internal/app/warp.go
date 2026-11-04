package app

import (
	"context"
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/yourname/freev6/internal/warp"
)

type WarpRegistrar interface {
	RegisterWithProgress(context.Context, string, func(string)) (warp.Device, error)
}

type WarpCredential struct {
	SchemaVersion int         `json:"schemaVersion"`
	Device        warp.Device `json:"device"`
}

func NormalizeWarpDeviceName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		name = "freev6-macos"
	}
	if !utf8.ValidString(name) || len(name) > 128 {
		return "", fmt.Errorf("device name must be at most 128 UTF-8 bytes")
	}
	for _, c := range name {
		if unicode.IsControl(c) {
			return "", fmt.Errorf("device name contains control characters")
		}
	}
	return name, nil
}

// Registration has no storage side effects. The caller owns credential storage
// and must confirm it separately before reporting a usable local account.
func RegisterWarp(ctx context.Context, registrar WarpRegistrar, name string, progress func(string)) (WarpCredential, error) {
	name, err := NormalizeWarpDeviceName(name)
	if err != nil {
		return WarpCredential{}, err
	}
	device, err := registrar.RegisterWithProgress(ctx, name, progress)
	if err != nil {
		return WarpCredential{}, err
	}
	if err := warp.ValidateDevice(device); err != nil {
		return WarpCredential{}, err
	}
	return WarpCredential{SchemaVersion: 1, Device: device}, nil
}
