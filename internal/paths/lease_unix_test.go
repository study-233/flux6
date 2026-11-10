//go:build darwin || linux

package paths

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLeaseRejectsSecondWorkerAndSymlinkResources(t *testing.T) {
	dir := t.TempDir()
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	first, err := AcquireWorkerLease(root)
	if err != nil {
		t.Fatal(err)
	}
	if second, err := AcquireWorkerLease(root); err == nil {
		second.Close()
		t.Fatal("second worker acquired lease")
	}
	first.Close()
	third, err := AcquireWorkerLease(root)
	if err != nil {
		t.Fatal(err)
	}
	third.Close()
	resource := filepath.Join(dir, "resources")
	if err := os.Mkdir(resource, 0o700); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(dir, "alias")
	if err := os.Symlink(resource, alias); err != nil {
		t.Fatal(err)
	}
	d := Directories{Data: filepath.Join(alias, "data"), Resources: resource, Cache: filepath.Join(dir, "cache"), Logs: filepath.Join(dir, "logs")}
	if err := d.Prepare(); err == nil {
		t.Fatal("accepted resources through symlink")
	}
}
