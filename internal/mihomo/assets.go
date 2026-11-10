package mihomo

import (
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"path/filepath"
)

//go:embed runtime-assets.json
var runtimeAssetCatalog []byte

type RuntimeAsset struct {
	OS           string `json:"os"`
	Arch         string `json:"arch"`
	Archive      string `json:"archive"`
	Binary       string `json:"binary"`
	SHA256       string `json:"sha256"`
	BinarySHA256 string `json:"binarySha256"`
	Version      string `json:"-"`
}

func PinnedRuntimeAsset(goos, goarch string) (RuntimeAsset, error) {
	var catalog struct {
		Version string         `json:"version"`
		Assets  []RuntimeAsset `json:"assets"`
	}
	if err := json.Unmarshal(runtimeAssetCatalog, &catalog); err != nil {
		return RuntimeAsset{}, err
	}
	for _, asset := range catalog.Assets {
		if asset.OS != goos || asset.Arch != goarch {
			continue
		}
		asset.Version = catalog.Version
		if err := asset.validate(); err != nil {
			return RuntimeAsset{}, err
		}
		return asset, nil
	}
	return RuntimeAsset{}, fmt.Errorf("unsupported mihomo platform: %s/%s", goos, goarch)
}

func (a RuntimeAsset) validate() error {
	for _, name := range []string{a.Archive, a.Binary, a.Version} {
		if name == "" || name == "." || name == ".." || filepath.Base(name) != name || !safeAssetName(name) {
			return fmt.Errorf("invalid runtime asset name")
		}
	}
	for _, value := range []string{a.SHA256, a.BinarySHA256} {
		digest, err := hex.DecodeString(value)
		if err != nil || len(digest) != 32 {
			return fmt.Errorf("invalid pinned runtime digest")
		}
	}
	if a.OS == "windows" && a.Arch == "amd64" && filepath.Ext(a.Archive) == ".zip" {
		return nil
	}
	if a.OS == "darwin" && (a.Arch == "arm64" || a.Arch == "amd64") && filepath.Ext(a.Archive) == ".gz" {
		return nil
	}
	return fmt.Errorf("unsupported runtime asset format or architecture")
}

func safeAssetName(name string) bool {
	for _, c := range name {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') {
			return false
		}
	}
	return true
}

func (a RuntimeAsset) SourceURLs() []string {
	url := "https://github.com/MetaCubeX/mihomo/releases/download/" + a.Version + "/" + a.Archive
	return []string{"https://v6.gh-proxy.org/" + url, "https://v4.gh-proxy.org/" + url,
		"https://gh-proxy.com/" + url, "https://axisnow.gh-proxy.org/" + url, "https://cdn.gh-proxy.org/" + url, url}
}

func (a RuntimeAsset) ResourceID() string { return "mihomo-" + a.OS + "-" + a.Arch + "-" + a.Version }
