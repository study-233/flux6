package warp

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/x509"
	"encoding/base64"
	"fmt"
	"net/netip"
)

func validDeviceID(value string) bool {
	if len(value) == 0 || len(value) > 256 {
		return false
	}
	for _, c := range value {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

func validToken(value string) bool {
	if len(value) == 0 || len(value) > 8192 {
		return false
	}
	for _, c := range value {
		if c < 0x21 || c > 0x7e {
			return false
		}
	}
	return true
}

// ValidateDevice contains no credential text in any returned error. The Mac
// worker validates before handing secrets to the app's Keychain boundary.
func ValidateDevice(device Device) error {
	if !validDeviceID(device.DeviceID) || !validToken(device.Token) {
		return fmt.Errorf("invalid WARP account identity")
	}
	if device.RegisteredAt.IsZero() {
		return fmt.Errorf("invalid WARP registration date")
	}
	return ValidateTunnelCredentials(TunnelCredentials{device.PrivateKey, device.PeerPublicKey, device.IPv4, device.IPv6})
}

// TunnelCredentials deliberately excludes the registration token and account
// identity. Only these four values are needed to render MASQUE outbounds.
type TunnelCredentials struct {
	PrivateKey    string `json:"privateKey"`
	PeerPublicKey string `json:"peerPublicKey"`
	IPv4          string `json:"ipv4"`
	IPv6          string `json:"ipv6"`
}

func (TunnelCredentials) String() string   { return "TunnelCredentials(redacted)" }
func (TunnelCredentials) GoString() string { return "TunnelCredentials(redacted)" }

func ValidateTunnelCredentials(device TunnelCredentials) error {
	if len(device.PrivateKey) > 4096 || len(device.PeerPublicKey) > 4096 {
		return fmt.Errorf("invalid WARP key size")
	}
	privateDER, err := base64.StdEncoding.Strict().DecodeString(device.PrivateKey)
	if err != nil {
		return fmt.Errorf("invalid WARP private key")
	}
	privateKey, err := x509.ParseECPrivateKey(privateDER)
	if err != nil || privateKey.Curve != elliptic.P256() {
		return fmt.Errorf("invalid WARP private key")
	}
	publicDER, err := base64.StdEncoding.Strict().DecodeString(device.PeerPublicKey)
	if err != nil {
		return fmt.Errorf("invalid WARP peer key")
	}
	parsed, err := x509.ParsePKIXPublicKey(publicDER)
	if err != nil {
		return fmt.Errorf("invalid WARP peer key")
	}
	publicKey, ok := parsed.(*ecdsa.PublicKey)
	if !ok || publicKey.Curve != elliptic.P256() {
		return fmt.Errorf("invalid WARP peer key")
	}
	v4, err4 := netip.ParseAddr(device.IPv4)
	v6, err6 := netip.ParseAddr(device.IPv6)
	if err4 != nil || !v4.Is4() || err6 != nil || !v6.Is6() || v6.Is4In6() || v6.Zone() != "" {
		return fmt.Errorf("invalid WARP interface addresses")
	}
	return nil
}
