// macos-probe generates offline validation fixtures. The generated credentials
// are synthetic and cannot establish a WARP session. It never starts a core.
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/yourname/freev6/internal/app"
	"github.com/yourname/freev6/internal/mihomo"
	"github.com/yourname/freev6/internal/warp"
)

func main() {
	out := flag.String("out", "build/macos-probes/config", "isolated fixture directory")
	flag.Parse()
	if err := generate(*out); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func generate(directory string) error {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	private, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return err
	}
	public, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		return err
	}
	device := warp.Device{PrivateKey: base64.StdEncoding.EncodeToString(private), PeerPublicKey: base64.StdEncoding.EncodeToString(public), IPv4: "172.16.0.2", IPv6: "2001:db8::2"}
	data, err := mihomo.RenderJSONWithOptions(device, mihomo.RenderOptions{Platform: mihomo.PlatformDarwin, ControllerSecret: "offline-probe-only"})
	if err != nil {
		return err
	}
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	var configuration map[string]any
	if err := json.Unmarshal(data, &configuration); err != nil {
		return err
	}
	business, err := app.PrepareWarpConfiguration(app.DefaultProxyPreferences(), warp.TunnelCredentials{
		PrivateKey: device.PrivateKey, PeerPublicKey: device.PeerPublicKey, IPv4: device.IPv4, IPv6: device.IPv6,
	})
	if err != nil {
		return err
	}
	businessData, err := json.Marshal(business)
	if err != nil {
		return err
	}
	var businessFields map[string]any
	if err := json.Unmarshal(businessData, &businessFields); err != nil {
		return err
	}
	for key, value := range businessFields {
		configuration[key] = value
	}
	data, err = json.Marshal(configuration)
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(directory, "full-config.json"), data, 0o600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(directory, "business-config.json"), businessData, 0o600); err != nil {
		return err
	}
	// Isolate MASQUE parsing from external GeoSite/provider availability. The
	// full product configuration is retained above for separate integration tests.
	delete(configuration, "rule-providers")
	configuration["rules"] = []string{"MATCH,🚀 节点选择"}
	delete(configuration["dns"].(map[string]any), "nameserver-policy")
	data, err = json.MarshalIndent(configuration, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(directory, "offline-config.json"), data, 0o600); err != nil {
		return err
	}
	fmt.Println("Generated business, full and offline MASQUE fixtures; synthetic credentials only")
	return nil
}
