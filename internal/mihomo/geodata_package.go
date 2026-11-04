package mihomo

import (
	"context"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

//go:embed geodata-assets.json
var geodataAssetCatalog []byte

type GeodataAsset struct {
	Name       string `json:"name"`
	SourceName string `json:"sourceName"`
	Size       int64  `json:"size"`
	SHA256     string `json:"sha256"`
}

type GeodataCatalog struct {
	Revision string         `json:"revision"`
	Source   string         `json:"source"`
	Assets   []GeodataAsset `json:"assets"`
}

func PinnedGeodata() (GeodataCatalog, error) {
	var catalog GeodataCatalog
	if err := json.Unmarshal(geodataAssetCatalog, &catalog); err != nil {
		return catalog, err
	}
	return catalog, catalog.validate()
}

func (c GeodataCatalog) validate() error {
	revision, err := hex.DecodeString(c.Revision)
	if err != nil || len(revision) != 20 || len(c.Assets) != 3 {
		return errors.New("invalid geodata catalog")
	}
	names := map[string]string{GeositeFileName: "geosite.dat", GeoipFileName: "geoip.dat", MmdbFileName: "country.mmdb"}
	for _, asset := range c.Assets {
		digest, err := hex.DecodeString(asset.SHA256)
		if names[asset.Name] == "" || names[asset.Name] != asset.SourceName || err != nil || len(digest) != 32 || asset.Size <= 0 || asset.Size > maxGeositeSize {
			return errors.New("invalid pinned geodata asset")
		}
		delete(names, asset.Name)
	}
	return nil
}

func (c GeodataCatalog) SourceURLs(a GeodataAsset) []string {
	path := "MetaCubeX/meta-rules-dat/" + c.Revision + "/" + a.SourceName
	return []string{
		"https://v6.gh-proxy.org/https://raw.githubusercontent.com/" + path,
		"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@" + c.Revision + "/" + a.SourceName,
		"https://raw.githubusercontent.com/" + path,
	}
}

type GeodataFile struct {
	Name      string `json:"name"`
	Size      int64  `json:"size"`
	SHA256    string `json:"sha256"`
	Available bool   `json:"available"`
}

type GeodataPackage struct {
	ResourceID string        `json:"resourceId"`
	Revision   string        `json:"revision"`
	Available  bool          `json:"available"`
	Files      []GeodataFile `json:"files"`
	Directory  string        `json:"-"`
}

type GeodataProgress struct {
	RuntimeProgress
	Asset string `json:"asset"`
}

type geodataPreparer struct {
	catalog               GeodataCatalog
	client                *http.Client
	sources               func(GeodataAsset) []string
	stall, hard, interval time.Duration
}

func newGeodataPreparer() (geodataPreparer, error) {
	catalog, err := PinnedGeodata()
	return geodataPreparer{catalog: catalog, client: pinnedHTTPClient(), sources: catalog.SourceURLs,
		stall: 10 * time.Second, hard: time.Minute, interval: time.Second}, err
}

// InspectGeodataPackage only checks the fixed cache set. A seed is not ready
// until copied and verified in the cache; no writes or downloads happen here.
func InspectGeodataPackage(ctx context.Context, cacheDir string) (GeodataPackage, error) {
	p, err := newGeodataPreparer()
	if err != nil {
		return GeodataPackage{}, err
	}
	return p.inspect(ctx, cacheDir)
}

// PrepareGeodataPackage never writes into the bundle and never runs a core.
// All three files must match the embedded catalog. The privileged service must
// reverify copies using its own trusted catalog before opening them as root.
func PrepareGeodataPackage(ctx context.Context, resourceDir, cacheDir string, progress func(GeodataProgress)) (GeodataPackage, error) {
	p, err := newGeodataPreparer()
	if err != nil {
		return GeodataPackage{}, err
	}
	return p.prepare(ctx, resourceDir, cacheDir, progress)
}

func (p geodataPreparer) inspect(ctx context.Context, cacheDir string) (GeodataPackage, error) {
	info := GeodataPackage{ResourceID: "geodata-" + p.catalog.Revision, Revision: p.catalog.Revision,
		Directory: filepath.Join(cacheDir, "geodata", p.catalog.Revision), Available: true, Files: []GeodataFile{}}
	if err := p.catalog.validate(); err != nil {
		return info, err
	}
	for _, asset := range p.catalog.Assets {
		if err := ctx.Err(); err != nil {
			return info, err
		}
		err := verifyRuntimeFile(ctx, filepath.Join(info.Directory, asset.Name), asset.SHA256, asset.Size)
		if ctx.Err() != nil {
			return info, ctx.Err()
		}
		available := err == nil
		info.Files = append(info.Files, GeodataFile{asset.Name, asset.Size, asset.SHA256, available})
		info.Available = info.Available && available
	}
	return info, nil
}

func (p geodataPreparer) prepare(ctx context.Context, resourceDir, cacheDir string, progress func(GeodataProgress)) (GeodataPackage, error) {
	notify := func(asset, phase string, received, total int64, attempt, attempts int) {
		if progress != nil {
			progress(GeodataProgress{RuntimeProgress{phase, received, total, attempt, attempts}, asset})
		}
	}
	notify("", "checking", 0, -1, 0, 0)
	info, err := p.inspect(ctx, cacheDir)
	if err != nil || info.Available {
		return info, err
	}
	if err := os.MkdirAll(info.Directory, 0o700); err != nil {
		return info, err
	}
	for i, asset := range p.catalog.Assets {
		if err := ctx.Err(); err != nil {
			return info, err
		}
		if info.Files[i].Available {
			continue
		}
		// The caller supplies Bundle.resourceURL, never a guessed executable parent.
		seed := filepath.Join(resourceDir, "Geodata", p.catalog.Revision, asset.Name)
		var temporary string
		if verifyRuntimeFile(ctx, seed, asset.SHA256, asset.Size) == nil {
			notify(asset.Name, "copying", 0, asset.Size, 0, 0)
			temporary, err = copyPinnedGeodata(ctx, seed, info.Directory, asset)
			if err != nil {
				return info, err
			}
		} else {
			var failures []string
			sources := p.sources(asset)
			for index, source := range sources {
				if err := ctx.Err(); err != nil {
					return info, err
				}
				emit := func(n, total int64) { notify(asset.Name, "downloading", n, total, index+1, len(sources)) }
				emit(0, asset.Size)
				transfer := pinnedTransfer{client: p.client, digest: asset.SHA256, limit: asset.Size,
					stall: p.stall, hard: p.hard, interval: p.interval}
				temporary, err = transfer.download(ctx, source, info.Directory, emit)
				if err == nil {
					break
				}
				failures = append(failures, hostOf(source))
			}
			if temporary == "" {
				if err := ctx.Err(); err != nil {
					return info, err
				}
				return info, fmt.Errorf("准备 %s 失败（已尝试 %d 个来源：%s），请检查网络后重试", asset.Name, len(failures), strings.Join(failures, ", "))
			}
		}
		notify(asset.Name, "verifying", asset.Size, asset.Size, 0, 0)
		if err := commitGeodata(ctx, temporary, filepath.Join(info.Directory, asset.Name), asset); err != nil {
			return info, err
		}
		info.Files[i].Available = true
	}
	// Re-read the complete set so a partial or changed cache cannot report ready.
	return p.inspect(ctx, cacheDir)
}

func copyPinnedGeodata(ctx context.Context, source, directory string, asset GeodataAsset) (string, error) {
	input, err := os.Open(source)
	if err != nil {
		return "", err
	}
	defer input.Close()
	output, err := os.CreateTemp(directory, ".freev6-geodata-*")
	if err != nil {
		return "", err
	}
	keep := false
	defer func() {
		output.Close()
		if !keep {
			os.Remove(output.Name())
		}
	}()
	_, err = io.Copy(output, io.LimitReader(runtimeContextReader{ctx, input}, asset.Size+1))
	if err != nil {
		return "", err
	}
	if err = output.Sync(); err != nil {
		return "", err
	}
	if err = output.Close(); err != nil {
		return "", err
	}
	if err = verifyRuntimeFile(ctx, output.Name(), asset.SHA256, asset.Size); err != nil {
		return "", err
	}
	keep = true
	return output.Name(), nil
}

func commitGeodata(ctx context.Context, temporary, destination string, asset GeodataAsset) error {
	defer os.Remove(temporary)
	if err := verifyRuntimeFile(ctx, temporary, asset.SHA256, asset.Size); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := os.Rename(temporary, destination); err != nil {
		return err
	}
	return syncRuntimeDirectory(filepath.Dir(destination))
}
