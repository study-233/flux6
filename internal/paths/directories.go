package paths

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

type Directories struct{ Data, Resources, Cache, Logs string }

// Prepare requires explicit directories; the worker never guesses a writable
// directory from its executable or writes into the resource bundle.
func (d Directories) Prepare() error {
	resolved := make([]string, 0, 4)
	for _, directory := range []string{d.Data, d.Resources, d.Cache, d.Logs} {
		if directory == "" || !filepath.IsAbs(directory) {
			return errors.New("all worker directories must be absolute")
		}
		path, err := canonical(directory)
		if err != nil {
			return err
		}
		resolved = append(resolved, path)
	}
	for i, a := range resolved {
		for j, b := range resolved {
			if i != j && within(a, b) {
				return errors.New("worker directories must not overlap")
			}
		}
	}
	info, err := os.Stat(d.Resources)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return errors.New("resource directory must exist")
	}
	for _, directory := range []string{d.Data, d.Cache, d.Logs} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			return err
		}
	}
	return nil
}

func canonical(path string) (string, error) {
	path = filepath.Clean(path)
	resolved, err := filepath.EvalSymlinks(path)
	if err == nil {
		return resolved, nil
	}
	if !os.IsNotExist(err) {
		return "", err
	}
	parent, err := canonical(filepath.Dir(path))
	if err != nil {
		return "", err
	}
	return filepath.Join(parent, filepath.Base(path)), nil
}

func within(parent, child string) bool {
	rel, err := filepath.Rel(parent, child)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}
