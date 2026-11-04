package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/yourname/freev6/internal/paths"
	"github.com/yourname/freev6/internal/warp"
	"github.com/yourname/freev6/internal/worker"
)

func run() error {
	var dirs paths.Directories
	flag.StringVar(&dirs.Data, "data-dir", "", "private user data directory")
	flag.StringVar(&dirs.Resources, "resource-dir", "", "read-only bundle resources")
	flag.StringVar(&dirs.Cache, "cache-dir", "", "user cache directory")
	flag.StringVar(&dirs.Logs, "log-dir", "", "user log directory")
	flag.Parse()
	if flag.NArg() != 0 {
		return fmt.Errorf("unexpected worker argument")
	}
	if os.Geteuid() == 0 {
		return fmt.Errorf("worker must run as the logged-in user")
	}
	if err := dirs.Prepare(); err != nil {
		return err
	}
	root, err := os.OpenRoot(dirs.Data)
	if err != nil {
		return err
	}
	defer root.Close()
	lease, err := paths.AcquireWorkerLease(root)
	if err != nil {
		return err
	}
	defer lease.Close()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	input, output, err := worker.StandardPipes()
	if err != nil {
		return err
	}
	handler := worker.BusinessHandler(worker.NewSettingsStore(root), worker.NewRuntimeManager(dirs.Cache))
	handler = worker.WarpHandler(worker.NewWarpManager(warp.NewClient(nil)), handler)
	return worker.Serve(ctx, input, output, handler, worker.ServerOptions{Capabilities: []string{"settings.get", "settings.patch", "runtime.status", "runtime.download", "warp.register"}})
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "freev6-worker:", err)
		os.Exit(1)
	}
}
