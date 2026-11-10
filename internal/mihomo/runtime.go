package mihomo

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

var ErrBinaryNotFound = errors.New("mihomo runtime binary not found")

// RuntimeCandidates returns paths in preference order for the current platform.
// The runtime directory is the installed layout; state is retained for local development.
func RuntimeCandidates(root string) []string {
	return RuntimeCandidatesFor(root, runtime.GOOS, runtime.GOARCH)
}

// RuntimeCandidatesFor makes target selection independent of the build host.
// Windows keeps its established v3 preference; Intel Mac prefers the v1 CPU
// baseline. Unix executables never acquire a Windows extension.
func RuntimeCandidatesFor(root, goos, goarch string) []string {
	extension := ""
	if goos == "windows" {
		extension = ".exe"
	}
	name := "mihomo-" + goos + "-" + goarch
	names := []string{name + extension, "mihomo" + extension}
	if goarch == "amd64" {
		if goos == "windows" {
			names = append([]string{name + "-v3.exe"}, names...)
		} else if goos == "darwin" {
			names = append([]string{name + "-v1"}, names...)
		}
	}
	var paths []string
	for _, directory := range []string{"runtime", "state"} {
		for _, candidate := range names {
			paths = append(paths, filepath.Join(root, directory, candidate))
		}
	}
	return paths
}

func DiscoverBinary(root string) (string, error) {
	if root == "" {
		root = "."
	}
	for _, candidate := range RuntimeCandidates(root) {
		info, err := os.Stat(candidate)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			return "", fmt.Errorf("inspect mihomo runtime %q: %w", candidate, err)
		}
		if info.IsDir() {
			continue
		}
		return candidate, nil
	}
	return "", fmt.Errorf("%w under %q", ErrBinaryNotFound, root)
}

func ResolveBinary(explicit, root string) (string, error) {
	if explicit != "" {
		info, err := os.Stat(explicit)
		if err != nil {
			return "", fmt.Errorf("inspect mihomo binary %q: %w", explicit, err)
		}
		if info.IsDir() {
			return "", fmt.Errorf("mihomo binary path %q is a directory", explicit)
		}
		return explicit, nil
	}
	return DiscoverBinary(root)
}
