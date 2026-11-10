package app

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

const MaxSubscriptionBytes = 2 << 20

// FetchSubscription reads a snapshot only on an explicit import or refresh.
func FetchSubscription(ctx context.Context, rawURL string) ([]byte, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return nil, errors.New("订阅地址必须是 http(s) URL")
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	// Some subscription hosts reject the default Go UA.
	request.Header.Set("User-Agent", "Flux6")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("HTTP %s", response.Status)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, MaxSubscriptionBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > MaxSubscriptionBytes {
		return nil, fmt.Errorf("订阅内容超过 2MB 上限")
	}
	return data, nil
}
