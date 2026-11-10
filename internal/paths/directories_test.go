package paths

import (
	"os"
	"path/filepath"
	"testing"
)

func TestExplicitWritableDirectories(t *testing.T) {
	root := t.TempDir()
	d := Directories{Data: filepath.Join(root, "data"), Resources: filepath.Join(root, "resources"), Cache: filepath.Join(root, "cache"), Logs: filepath.Join(root, "logs")}
	if err := os.Mkdir(d.Resources, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := d.Prepare(); err != nil {
		t.Fatal(err)
	}
	bad := d
	bad.Data = filepath.Join(d.Resources, "state")
	if err := bad.Prepare(); err == nil {
		t.Fatal("accepted bundle writes")
	}
	if _, err := os.Stat(bad.Data); !os.IsNotExist(err) {
		t.Fatal("created resource child before validation")
	}
	bad = d
	bad.Cache = "relative"
	if err := bad.Prepare(); err == nil {
		t.Fatal("accepted implicit relative path")
	}
}
