package app

import (
	"encoding/json"
	"errors"

	"github.com/yourname/freev6/internal/mihomo"
	"github.com/yourname/freev6/internal/warp"
)

const MaxBusinessConfigurationBytes = 512 * 1024

// BusinessConfiguration is the ordinary-user half of a native connection.
// System fields are deliberately excluded. The service supplies DNS/TUN,
// controller, logging and paths after independently validating this document.
type BusinessConfiguration struct {
	Mode          string                     `json:"mode"`
	Proxies       []json.RawMessage          `json:"proxies"`
	ProxyGroups   []json.RawMessage          `json:"proxy-groups"`
	RuleProviders map[string]json.RawMessage `json:"rule-providers"`
	Rules         []string                   `json:"rules"`
}

func (BusinessConfiguration) String() string   { return "BusinessConfiguration(redacted)" }
func (BusinessConfiguration) GoString() string { return "BusinessConfiguration(redacted)" }

// PrepareWarpConfiguration reuses the shared renderer and Windows blacklist
// semantics. It does not read credentials, write a config file or run a core.
func PrepareWarpConfiguration(preferences ProxyPreferences, tunnel warp.TunnelCredentials) (BusinessConfiguration, error) {
	return PrepareWarpWithChain(preferences, tunnel, nil)
}

func PrepareWarpWithChain(preferences ProxyPreferences, tunnel warp.TunnelCredentials, chain []mihomo.ChainProxy) (BusinessConfiguration, error) {
	if err := warp.ValidateTunnelCredentials(tunnel); err != nil {
		return BusinessConfiguration{}, errors.New("invalid tunnel credentials")
	}
	device := warp.Device{PrivateKey: tunnel.PrivateKey, PeerPublicKey: tunnel.PeerPublicKey, IPv4: tunnel.IPv4, IPv6: tunnel.IPv6}
	return prepareBusiness(preferences, device, mihomo.RenderOptions{ChainProxies: chain})
}

func PrepareCloudConfiguration(preferences ProxyPreferences, nodes []mihomo.ChainProxy) (BusinessConfiguration, error) {
	if len(nodes) == 0 || len(nodes) > mihomo.CloudMaxNodes {
		return BusinessConfiguration{}, errors.New("invalid campus exits")
	}
	return prepareBusiness(preferences, warp.Device{}, mihomo.RenderOptions{CloudNodes: nodes})
}

func prepareBusiness(preferences ProxyPreferences, device warp.Device, options mihomo.RenderOptions) (BusinessConfiguration, error) {
	var result BusinessConfiguration
	encoded, err := json.Marshal(preferences)
	if err != nil {
		return result, errors.New("invalid proxy preferences")
	}
	preferences, err = PatchProxyPreferences(DefaultProxyPreferences(), encoded)
	if err != nil {
		return result, errors.New("invalid proxy preferences")
	}
	blacklist := preferences.Blacklist
	if len(blacklist) == 0 {
		blacklist, err = mihomo.DefaultBlacklist()
		if err != nil {
			return result, errors.New("invalid built-in blacklist")
		}
	}
	options.Platform = mihomo.PlatformDarwin
	options.Mode = preferences.Mode
	options.CampusCIDRs = preferences.CampusCIDRs
	options.Blacklist = blacklist
	options.DevMode = preferences.DevMode
	data, err := mihomo.RenderJSONWithOptions(device, options)
	if err != nil {
		return result, errors.New("cannot render business configuration")
	}
	// Decode only the explicitly allowed business fields; privileged fields
	// from the shared full-core renderer cannot enter the worker response.
	if err := json.Unmarshal(data, &result); err != nil {
		return result, errors.New("invalid generated configuration")
	}
	if result.RuleProviders == nil {
		result.RuleProviders = map[string]json.RawMessage{}
	}
	encoded, err = json.Marshal(result)
	if err != nil || len(encoded) > MaxBusinessConfigurationBytes {
		return BusinessConfiguration{}, errors.New("business configuration exceeds limit")
	}
	return result, nil
}
