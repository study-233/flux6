//go:build windows

// Explicitly built test sidecar. Never included as the product helper.
package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

type acceptanceConfig struct {
	NativeHelper string `json:"nativeHelper"`
	EvidenceRoot string `json:"evidenceRoot"`
}

func acceptanceHandler(token string, native http.Handler, audit func(string, string, string)) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if token == "" || r.Header.Get("Authorization") != "Bearer "+token {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		path := r.URL.Path
		allowed := r.Method == http.MethodGet && (path == "/api/v1/status" || path == "/api/v1/runtime" || path == "/api/v1/settings" || path == "/api/v1/appearance" || path == "/api/v1/chain-proxy" || path == "/api/v1/cloud-config")
		allowed = allowed || (r.Method == http.MethodPut && path == "/api/v1/settings")
		if allowed {
			audit(r.Method, path, "native-local")
			native.ServeHTTP(w, r)
			return
		}
		audit(r.Method, path, "offline-intercept")
		if r.Method == http.MethodGet && path == "/api/v1/notice" {
			fmt.Fprint(w, `{"ok":true,"notices":[],"stale":true,"offlineAcceptance":true}`)
		} else if r.Method == http.MethodGet && path == "/api/v1/update/latest" {
			fmt.Fprint(w, `{"ok":true,"update":false,"offlineAcceptance":true}`)
		} else if r.Method == http.MethodPost && path == "/api/v1/proxy/stop" {
			// Startup refuses all real PID/snapshot inputs, and start is blocked.
			fmt.Fprint(w, `{"ok":true,"running":false,"offlineAcceptance":true}`)
		} else {
			w.WriteHeader(http.StatusServiceUnavailable)
			fmt.Fprint(w, `{"error":"Offline acceptance: network operation blocked","code":"offline_acceptance"}`)
		}
	})
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--autostart" {
		return
	}
	if err := runAcceptance(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func runAcceptance() error {
	root := os.Getenv("FREEV6_ROOT")
	for _, name := range []string{"mihomo.pid", "network-snapshot.json", "warp.json"} {
		if _, err := os.Stat(filepath.Join(root, "state", name)); !os.IsNotExist(err) {
			return fmt.Errorf("refusing existing network state: %s", name)
		}
	}
	var config acceptanceConfig
	data, err := os.ReadFile(filepath.Join(root, "state", "offline-acceptance.json"))
	if err != nil {
		return err
	}
	if err = json.Unmarshal(data, &config); err != nil {
		return err
	}
	front, err := net.Listen("tcp4", "127.0.0.1:"+os.Getenv("FREEV6_API_PORT"))
	if err != nil {
		return err
	}
	defer front.Close()
	reserve, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	port := reserve.Addr().(*net.TCPAddr).Port
	reserve.Close()
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(job)
	limits := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err = windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits))); err != nil {
		return err
	}
	child := exec.Command(config.NativeHelper)
	child.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NO_WINDOW}
	child.Dir = root
	child.Env = append(os.Environ(), fmt.Sprintf("FREEV6_API_PORT=%d", port))
	child.Stdout = os.Stdout
	child.Stderr = os.Stderr
	if err = child.Start(); err != nil {
		return err
	}
	process, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(child.Process.Pid))
	if err != nil {
		child.Process.Kill()
		return err
	}
	err = windows.AssignProcessToJobObject(job, process)
	windows.CloseHandle(process)
	if err != nil {
		child.Process.Kill()
		return err
	}
	go child.Wait()
	target, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port))
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.Transport = &http.Transport{Proxy: nil}
	var auditMutex sync.Mutex
	audit := func(method, path, action string) {
		auditMutex.Lock()
		defer auditMutex.Unlock()
		file, e := os.OpenFile(filepath.Join(config.EvidenceRoot, "requests.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
		if e == nil {
			defer file.Close()
			json.NewEncoder(file).Encode(map[string]any{"time": time.Now().Format(time.RFC3339), "method": method, "path": path, "action": action})
		}
	}
	// The controller reads this private local file; never print the token.
	session, _ := json.Marshal(map[string]any{"port": os.Getenv("FREEV6_API_PORT"), "token": os.Getenv("FREEV6_API_TOKEN"), "gatewayPid": os.Getpid(), "nativePid": child.Process.Pid})
	if err = os.WriteFile(filepath.Join(config.EvidenceRoot, "api-session.json"), session, 0600); err != nil {
		return err
	}
	server := http.Server{Handler: acceptanceHandler(os.Getenv("FREEV6_API_TOKEN"), proxy, audit), ReadHeaderTimeout: 5 * time.Second}
	return server.Serve(front)
}
