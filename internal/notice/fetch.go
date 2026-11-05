package notice

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"time"
)

func MirrorPrefixes() []string {
	return []string{"https://v6.gh-proxy.org/", "https://v4.gh-proxy.org/", "https://gh-proxy.com/",
		"https://axisnow.gh-proxy.org/", "https://cdn.gh-proxy.org/"}
}

func Sources(mirrors []string) []string {
	const direct = "https://github.com/evansrrr/free-v6/raw/main/notice.json"
	sources := make([]string, 0, len(mirrors)+1)
	for _, prefix := range mirrors {
		sources = append(sources, prefix+direct)
	}
	return append(sources, direct)
}

func trustedURL(raw string) error {
	u, err := url.Parse(raw)
	if err == nil && u.Scheme == "https" && u.User == nil && u.Port() == "" &&
		(u.Host == "github.com" || u.Host == "raw.githubusercontent.com" || slices.Contains(MirrorPrefixes(), "https://"+u.Host+"/")) {
		return nil
	}
	return errors.New("untrusted notice origin")
}

func FetchPublished(ctx context.Context, now time.Time) (Payload, error) {
	client := &http.Client{Timeout: 4 * time.Second, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("too many redirects")
		}
		return trustedURL(req.URL.String())
	}}
	return Fetch(ctx, client, Sources(MirrorPrefixes()), now, trustedURL)
}

// Fetch tries each configured route until a complete, valid bulletin arrives.
func Fetch(ctx context.Context, client *http.Client, sources []string, now time.Time, validate func(string) error) (Payload, error) {
	last := errors.New("no notice source")
	for _, source := range sources {
		if err := ctx.Err(); err != nil {
			return Payload{}, err
		}
		if err := validate(source); err != nil {
			last = err
			continue
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
		if err != nil {
			last = err
			continue
		}
		query := req.URL.Query()
		query.Set("ts", strconv.FormatInt(now.UnixNano(), 10))
		req.URL.RawQuery = query.Encode()
		data, err := readResponse(client, req)
		if err == nil {
			var payload Payload
			payload, err = Parse(data, now)
			if err == nil {
				return payload, nil
			}
		}
		last = err
	}
	return Payload{}, last
}
func readResponse(client *http.Client, req *http.Request) ([]byte, error) {
	response, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected HTTP status %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, MaxBytes+1))
	if len(data) > MaxBytes {
		return nil, errors.New("notice exceeds size limit")
	}
	return data, err
}
