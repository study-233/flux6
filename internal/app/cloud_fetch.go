package app

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

// cloudGateError 是服务端门禁的拒绝（HTTP 403）。它和学生能自愈的情况
// （没连校园网）是同一件事，所以单独给一个 code 让 UI 说人话，而不是把
// "HTTP 403" 直接甩到 toast 上。
type cloudGateError struct{ status string }

func (e *cloudGateError) Error() string {
	return "备用配置仅对校园网开放（" + e.status + "），请连接校园网后重试"
}

// cloudErrorCode 把错误映射成前端可判别的 code。
func CloudErrorCode(err error) string {
	var gate *cloudGateError
	if errors.As(err, &gate) {
		return "campus-only"
	}
	return "fetch-failed"
}

// cloudHTTPClient 是取备用配置专用客户端，和 DefaultClient 相比有三处刻意不同：
//
//  1. Proxy: nil —— 强制直连。用户机器上往往有系统代理（本机的 clash/mihomo），
//     DefaultClient 会继承它：请求绕回代理链甚至走 WARP，源 IP 不再是校园网，
//     结果要么 403，要么卡到超时。取配置必须是"本机 → 服务端"这一跳。
//  2. ForceAttemptHTTP2: false —— 部分校园网 v6 链路存在 PMTU 黑洞，h2 握手
//     会一直挂着；降到 HTTP/1.1 能过去。
//  3. 明确的分段超时 —— 握手/响应头各自限时，失败能早点变成可读错误。
var cloudHTTPClient = &http.Client{
	Timeout: 20 * time.Second,
	Transport: &http.Transport{
		Proxy:                 nil,
		ForceAttemptHTTP2:     false,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 15 * time.Second,
		DialContext: (&net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
	},
}

// FetchCloudProfile downloads the backup profile. Only plain http(s) reaches
// here; the response is size-capped like a file import.
//
// 错误文案一律不带入口地址：这些字符串会原样出现在 toast / 弹窗里，而
// 弹窗是"会被截图发群里"的东西。底层错误可能包含完整 URL，只返回错误类别。
func FetchCloudProfile(ctx context.Context, rawURL string) ([]byte, error) {
	return FetchCloudProfileWithLog(ctx, rawURL, nil)
}

// FetchCloudProfileWithLog optionally records local diagnostic details. The
// Windows helper supplies its private file logger; the Mac worker keeps its
// existing sanitized diagnostic policy by using FetchCloudProfile.
func FetchCloudProfileWithLog(ctx context.Context, rawURL string, logFailure func(string)) ([]byte, error) {
	return fetchCloudProfile(ctx, rawURL, cloudHTTPClient, logFailure)
}

func fetchCloudProfile(ctx context.Context, rawURL string, client *http.Client, logFailure func(string)) ([]byte, error) {
	log := func(message string) {
		if logFailure != nil {
			logFailure(message)
		}
	}
	data, err := cloudAttempt(ctx, rawURL, client, log)
	var fetchErr *cloudFetchError
	if err != nil && ctx.Err() == nil && errors.As(err, &fetchErr) && fetchErr.retryable {
		log("retry once after: " + fetchErr.reason)
		data, err = cloudAttempt(ctx, rawURL, client, log)
	}
	if err != nil {
		log("failed: " + err.Error())
	}
	return data, err
}

func cloudAttempt(ctx context.Context, rawURL string, client *http.Client, logFailure func(string)) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		logFailure("bad request: " + err.Error())
		return nil, &cloudFetchError{reason: "入口地址无效"}
	}
	request.Header.Set("User-Agent", "Flux6")
	response, err := client.Do(request)
	if err != nil {
		logFailure("do: " + err.Error())
		return nil, &cloudFetchError{reason: describeFetchFailure(err), retryable: isRetryableFetch(err)}
	}
	defer response.Body.Close()
	switch {
	case response.StatusCode == http.StatusForbidden, response.StatusCode == http.StatusUnauthorized:
		return nil, &cloudGateError{status: fmt.Sprint(response.StatusCode)}
	case response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices:
		return nil, fmt.Errorf("获取备用配置失败：服务端返回 HTTP %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, MaxSubscriptionBytes+1))
	if err != nil {
		logFailure("read body: " + err.Error())
		return nil, &cloudFetchError{reason: "响应读取中断", retryable: true}
	}
	if len(data) > MaxSubscriptionBytes {
		return nil, fmt.Errorf("备用配置超过 2MB 上限")
	}
	return data, nil
}

// isRetryableFetch 判定"再试一次有意义"：超时、连接被重置、网络不可达。
// 证书错误、DNS 不存在这类重试也不会变，直接放弃以免白等两个 20 秒。
func isRetryableFetch(err error) bool {
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return true
	}
	text := strings.ToLower(err.Error())
	for _, marker := range []string{"connection reset", "unexpected eof", "network is unreachable", "no route to host", "broken pipe"} {
		if strings.Contains(text, marker) {
			return true
		}
	}
	return false
}

// cloudFetchError 是"网络层失败"的脱敏错误：只给原因类别，不给地址。
type cloudFetchError struct {
	reason    string
	retryable bool
}

func (e *cloudFetchError) Error() string {
	return "获取备用配置失败：" + e.reason
}

// describeFetchFailure 把 net/http 的错误归成人类可读的类别。
// 绝不能直接 %w 透出：Go 的错误里带着完整 URL（Get "https://<slug>.…"）。
func describeFetchFailure(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return "请求超时，请稍后重试"
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return "请求超时，请稍后重试"
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return "域名解析失败，请检查网络或 DNS"
	}
	text := strings.ToLower(err.Error())
	switch {
	case strings.Contains(text, "connection refused"):
		return "连接被拒绝"
	case strings.Contains(text, "certificate"):
		return "证书校验失败"
	case strings.Contains(text, "no route to host"), strings.Contains(text, "network is unreachable"):
		return "网络不可达"
	}
	return "网络请求失败，请稍后重试"
}
