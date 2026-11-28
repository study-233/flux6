// Adapted from apps/android/core/service_check.go; see PROBE_SOURCES.md.
package main

import (
	"net/http"
	"strings"
)

const (
	// A sweep runs a few checks at a time so it cannot take every probe slot.
	// It therefore runs in waves, and a rule like Disney+ spends several
	// requests in sequence, so the run gets a multiple of the request budget.
	serviceCheckConcurrency  = 4
	serviceSweepBudgetFactor = 6

	// Region markers sit deep inside these pages; endpoints that answer with a
	// few lines get the small cap.
	serviceHtmlMaxBody  = 512 * 1024
	serviceSmallMaxBody = 16 * 1024

	// Gemini's region sits past 800 KiB, Prime Video's at times past 4 MiB.
	serviceScanMaxBody = 8 * 1024 * 1024
)

// Statuses a check reports. Dart maps each to a localized label, so these
// strings are part of the contract and cannot be reworded on one side alone.
const (
	serviceAvailable         = "available"
	serviceUnavailable       = "unavailable"
	serviceRestricted        = "restricted"
	serviceDisallowedIsp     = "disallowed-isp"
	serviceBlocked           = "blocked"
	serviceUnsupportedRegion = "unsupported-region"
	serviceOriginalsOnly     = "originals-only"
	serviceComingSoon        = "coming-soon"
	serviceTimeout           = "timeout"
	serviceFailed            = "failed"
)

// An empty Names runs every check.
type ServiceCheckParams struct {
	ProxyName string   `json:"proxy-name"`
	Names     []string `json:"names"`
	Timeout   int64    `json:"timeout"`
}

// runServiceCheck stamps Name; a blank Status means a rule has yet to judge it.
type ServiceCheckItem struct {
	Name         string   `json:"name"`
	Status       string   `json:"status"`
	Region       string   `json:"region,omitempty"`
	Delay        int64    `json:"delay,omitempty"`
	Chains       []string `json:"chains,omitempty"`
	CheckedAt    int64    `json:"checked-at"`
	CoreEpoch    uint64   `json:"core-epoch"`
	RouteVersion uint64   `json:"route-version"`
}

type serviceChecker struct {
	name  string
	check func(serviceEnv) ServiceCheckItem
}

var serviceCheckers = []serviceChecker{
	{name: "google", check: checkReachable("https://www.google.com/generate_204")},
	{name: "github", check: checkReachable("https://github.com/")},
	{name: "youtube", check: checkYouTubePremium},
	{name: "chatgpt", check: checkChatGpt},
	{name: "claude", check: checkClaude},
	{name: "gemini", check: checkGemini},
	{name: "netflix", check: checkNetflix},
	{name: "disney-plus", check: checkDisneyPlus},
	{name: "prime-video", check: checkPrimeVideo},
	{name: "spotify", check: checkSpotify},
	{name: "tiktok", check: checkTikTok},
	{name: "discord", check: checkDiscord},
	{name: "bilibili", check: checkBilibili},
}

// checkReachable is the rule for a target with no unlock semantics of its own.
func checkReachable(url string) func(serviceEnv) ServiceCheckItem {
	return func(env serviceEnv) ServiceCheckItem {
		result := env.get(url, 0)
		item := itemFrom(result)
		if item.Status != "" {
			return item
		}
		item.Status = statusFromCode(result.StatusCode)
		return item
	}
}

func itemFrom(result *ProbeResult) ServiceCheckItem {
	if result == nil {
		return ServiceCheckItem{Status: serviceFailed}
	}
	item := ServiceCheckItem{Delay: result.Delay, Chains: result.Chains}
	switch result.Error {
	case "":
	case probeErrorTimeout:
		item.Status = serviceTimeout
		item.Delay = 0
	default:
		item.Status = serviceFailed
		item.Delay = 0
	}
	return item
}

func statusFromCode(code int) string {
	switch {
	case code >= 200 && code < 300:
		return serviceAvailable
	case code == http.StatusUnauthorized,
		code == http.StatusForbidden,
		code == http.StatusTooManyRequests,
		code == http.StatusUnavailableForLegalReasons:
		return serviceRestricted
	default:
		return serviceUnavailable
	}
}

func answered(item ServiceCheckItem, result *ProbeResult) bool {
	return item.Status == "" && result != nil
}

func bodyContains(result *ProbeResult, needles ...string) bool {
	if result.lowerBody == "" {
		result.lowerBody = strings.ToLower(result.Body)
	}
	for _, needle := range needles {
		if strings.Contains(result.lowerBody, needle) {
			return true
		}
	}
	return false
}

func traceValue(body string, key string) string {
	for _, line := range strings.Split(body, "\n") {
		if rest, found := strings.CutPrefix(line, key+"="); found {
			return strings.TrimSpace(rest)
		}
	}
	return ""
}
