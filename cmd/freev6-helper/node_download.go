package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"

	"net"
	"net/http"
	"net/netip"
	"net/url"
	"slices"
	"strconv"
	"sync"
	"time"

	"github.com/yourname/freev6/internal/mihomo"
	"gopkg.in/yaml.v3"
)

const (
	downloadLimit  = 32 << 20
	downloadTarget = "https://speed.cloudflare.com/__down"
	downloadUser   = "flux6-test"
	accessGroup    = "♻️ 自动选择"
)

type downloadChannel struct {
	probeContext                              context.Context
	stopProbes                                context.CancelFunc
	session, group, address, password, secret string
	controller                                netip.AddrPort
	latencyGroup, network                     string
	cloud                                     bool
	pid                                       int
	members                                   map[string][]string
	active                                    map[string]string
	pool                                      *accessPool
}

// Each core run gets a fresh selector name so mihomo's persistent selection
// cache and late cleanup from the previous run cannot select an old exit.
func prepareDownloadChannel(config, secret string, controller netip.AddrPort, balanceAccess bool) (*downloadChannel, string, error) {
	var topology struct {
		Proxies []struct{ Name, Server string }
		Groups  []struct {
			Name    string
			Proxies []string
		} `yaml:"proxy-groups"`
	}
	var document yaml.Node
	if err := yaml.Unmarshal([]byte(config), &document); err != nil {
		return nil, "", err
	}
	if err := document.Decode(&topology); err != nil {
		return nil, "", err
	}
	socket, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, "", err
	}
	port := socket.Addr().(*net.TCPAddr).Port
	socket.Close()
	id := rand.Text()
	c := &downloadChannel{session: id, group: "__Flux6_Test_" + id, address: net.JoinHostPort("127.0.0.1", strconv.Itoa(port)),
		password: rand.Text(), controller: controller, secret: secret, members: make(map[string][]string)}
	names := []string{"REJECT"}
	for _, p := range topology.Proxies {
		names = append(names, p.Name)
	}
	for _, g := range topology.Groups {
		if g.Name == accessGroup || g.Name == mihomo.ChainGroup {
			c.members[g.Name] = g.Proxies
		}
	}
	if len(names) < 2 || len(document.Content) != 1 {
		return nil, "", errors.New("missing proxies")
	}
	root := document.Content[0]
	// Modify the YAML syntax tree to retain scalar types, ordering and options
	// of every original proxy. The shared renderer owns the rest of the file.
	var selector, listener yaml.Node
	if err := selector.Encode(map[string]any{
		"name": c.group, "type": "select", "hidden": true, "proxies": names,
	}); err != nil {
		return nil, "", err
	}
	if err := listener.Encode(map[string]any{
		"name": "__Flux6_Download_In__", "type": "http", "listen": "127.0.0.1", "port": port, "proxy": c.group,
		"users": []map[string]string{{"username": downloadUser, "password": c.password}},
	}); err != nil {
		return nil, "", err
	}
	foundGroups := false
	for i := 0; i+1 < len(root.Content); i += 2 {
		switch root.Content[i].Value {
		case "external-controller":
			root.Content[i+1].Value = controller.String()
		case "proxy-groups":
			// Keep mihomo's latency selection as the default member. A real selector
			// can also pin an unavailable member without silently falling back.
			groups := root.Content[i+1]
			for _, item := range groups.Content {
				var original struct{ Name, Type string }
				if err := item.Decode(&original); err != nil {
					return nil, "", err
				}
				if original.Name != accessGroup || original.Type != "url-test" {
					continue
				}
				c.latencyGroup = "__Flux6_Latency_" + id
				for k := 0; k+1 < len(item.Content); k += 2 {
					if item.Content[k].Value == "name" {
						item.Content[k+1].Value = c.latencyGroup
					}
				}
				var access yaml.Node
				options := []string{c.latencyGroup}
				if balanceAccess && len(c.members[accessGroup]) >= 2 {
					var health struct{ URL string }
					if err := item.Decode(&health); err != nil {
						return nil, "", err
					}
					servers := make(map[string]string)
					for _, p := range topology.Proxies {
						servers[p.Name] = p.Server
					}
					c.pool = newAccessPool(id, c.members[accessGroup], servers)
					if err := c.pool.addGroups(groups, health.URL); err != nil {
						return nil, "", err
					}
					options = append([]string{c.pool.group(4)}, options...)
					for _, size := range []int{2, 8} {
						options = append(options, c.pool.group(size))
					}
				}
				if err := access.Encode(map[string]any{"name": accessGroup, "type": "select", "proxies": append(options, c.members[accessGroup]...)}); err != nil {
					return nil, "", err
				}
				groups.Content = append(groups.Content, &access)
				break
			}
			root.Content[i+1].Content = append(root.Content[i+1].Content, &selector)
			foundGroups = true
		case "listeners":
			return nil, "", errors.New("unexpected existing listeners in Windows configuration")
		}
	}
	if !foundGroups {
		return nil, "", errors.New("missing proxy groups")
	}
	root.Content = append(root.Content, &yaml.Node{Kind: yaml.ScalarNode, Value: "listeners"},
		&yaml.Node{Kind: yaml.SequenceNode, Content: []*yaml.Node{&listener}})
	data, err := yaml.Marshal(&document)
	return c, string(data), err
}

type nodeDownloads struct {
	mu         sync.Mutex
	channel    *downloadChannel
	cancel     context.CancelFunc
	background bool
	stopWorker context.CancelFunc
	quality    qualityStore
	problem    string
	loadErr    error
	rounds     map[string]*probeRound
	extended   []time.Time
}

func (d *nodeDownloads) activate(c *downloadChannel) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.activateLocked(c)
}
func (d *nodeDownloads) activateLocked(c *downloadChannel) {
	if d.channel != nil && d.channel.stopProbes != nil {
		d.channel.stopProbes()
	}
	if c != nil {
		c.probeContext, c.stopProbes = context.WithCancel(context.Background())
	}
	if d.cancel != nil {
		d.cancel()
	}
	if d.stopWorker != nil {
		d.stopWorker()
		d.stopWorker = nil
	}
	d.channel = c
}

func (d *nodeDownloads) connection(pid int, running bool) (string, uint16) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if running && d.channel != nil && d.channel.pid == pid {
		return d.channel.session, d.channel.controller.Port()
	}
	return "", 0
}

func (h *helper) measureNode(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var input struct {
		Session, Group, Node, Profile string
		Connections                   int
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&input); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "测速参数无效"})
		return
	}
	if input.Connections == 0 {
		input.Connections = 1
	}
	if input.Connections != 1 && input.Connections != 4 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "测速连接数须为 1 或 4"})
		return
	}
	d := &h.downloads
	d.mu.Lock()
	c := d.channel
	if c == nil || input.Session != c.session || input.Profile != "" && input.Profile != c.network {
		d.mu.Unlock()
		writeJSON(w, http.StatusConflict, map[string]string{"error": "连接已变更，请重新加载节点", "code": "session-changed"})
		return
	}
	if !slices.Contains(c.members[input.Group], input.Node) {
		d.mu.Unlock()
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "节点不在当前分组"})
		return
	}
	if d.cancel != nil {
		if d.background {
			d.cancel()
			d.mu.Unlock()
			writeJSON(w, 409, map[string]string{"error": "正在让出后台测速通道", "code": "auto-probe-yield"})
			return
		}
		d.mu.Unlock()
		writeJSON(w, http.StatusConflict, map[string]string{"error": "上一次测速正在收尾，请稍后再试", "code": "download-busy"})
		return
	}
	ctx, cancel := context.WithCancel(r.Context())
	profile := c.network
	d.cancel = cancel
	d.mu.Unlock()
	defer func() { d.mu.Lock(); d.cancel = nil; d.mu.Unlock(); cancel() }()

	result, err := c.measureTarget(ctx, input.Node, manualPlan(input.Connections), nil)
	result.Connections = input.Connections
	d.mu.Lock()
	if d.channel == c && c.network == profile && ctx.Err() == nil {
		h.saveSampleLocked(c, input.Group, input.Node, result, err, "manual")
	}
	d.mu.Unlock()
	if err != nil || ctx.Err() != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "测速失败，请检查节点或重新连接后重试"})
		return
	}
	writeJSON(w, http.StatusOK, result)
}

var localController = &http.Client{Transport: &http.Transport{}, Timeout: 2 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

func (c *downloadChannel) selectNode(ctx context.Context, node string) error {
	return c.selectGroup(ctx, c.group, node)
}

func (c *downloadChannel) selectGroup(ctx context.Context, group, node string) error {
	data, _ := json.Marshal(map[string]string{"name": node})
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, "http://"+c.controller.String()+"/proxies/"+url.PathEscape(group), bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.secret)
	req.Header.Set("Content-Type", "application/json")
	resp, err := localController.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("selector returned %d", resp.StatusCode)
	}
	return nil
}

func (c *downloadChannel) ownsListeners() bool {
	address, err := netip.ParseAddrPort(c.address)
	if err != nil || c.pid <= 0 {
		return false
	}
	owners := tcpListenerOwners()
	return owners[address] == c.pid && owners[c.controller] == c.pid
}

type downloadResult struct {
	Bytes          int64     `json:"bytes"`
	BytesPerSecond float64   `json:"bytesPerSecond"`
	MeasuredAt     time.Time `json:"measuredAt"`
	Connections    int       `json:"connections"`
	DurationMS     int64     `json:"durationMs"`
	SteadyRate     float64   `json:"steadyRate"`
}

// Only the loopback integration test supplies its own TLS endpoint and CA.
func (c *downloadChannel) measureTarget(ctx context.Context, node string, plan downloadPlan, tlsConfig *tls.Config) (result downloadResult, err error) {
	if !c.ownsListeners() {
		return result, errors.New("core listener unavailable")
	}
	defer func() {
		if !c.ownsListeners() {
			err = errors.New("core changed")
			return
		}
		if resetErr := c.selectNode(context.Background(), "REJECT"); resetErr != nil {
			err = resetErr
		}
	}()
	if err = c.selectNode(ctx, node); err != nil {
		return result, err
	}
	proxy := &url.URL{Scheme: "http", Host: c.address, User: url.UserPassword(downloadUser, c.password)}
	transport := &http.Transport{Proxy: http.ProxyURL(proxy), TLSClientConfig: tlsConfig, DisableCompression: true, DisableKeepAlives: true}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: localController.CheckRedirect}
	return sampleDownload(ctx, client, plan)
}
