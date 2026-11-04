package mihomo

import (
	"encoding/json"
	"fmt"

	"github.com/yourname/freev6/internal/warp"
	"gopkg.in/yaml.v3"
)

// RenderJSONWithOptions exposes the same business configuration as a structured
// document for the native service. The privileged service must still validate
// fields and assign its own controller, paths, credentials and network policy.
func RenderJSONWithOptions(device warp.Device, options RenderOptions) ([]byte, error) {
	text, err := RenderWithOptions(device, options)
	if err != nil {
		return nil, err
	}
	var configuration map[string]any
	if err := yaml.Unmarshal([]byte(text), &configuration); err != nil {
		return nil, fmt.Errorf("decode generated configuration: %w", err)
	}
	data, err := json.Marshal(configuration)
	if err != nil {
		return nil, fmt.Errorf("serialize configuration: %w", err)
	}
	return data, nil
}
