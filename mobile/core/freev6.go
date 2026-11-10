package core

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/yourname/freev6/mobileapi"
)

var warpRegistrationMu sync.Mutex

func registerFreeV6Warp() (string, error) {
	if !warpRegistrationMu.TryLock() {
		return "", errors.New("WARP registration is already in progress")
	}
	defer warpRegistrationMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	return mobileapi.RegisterWarp(ctx)
}

type freeV6ProfileParams struct {
	Credentials   string   `json:"credentials"`
	CampusTargets []string `json:"campus-targets"`
}

func renderFreeV6Profile(params freeV6ProfileParams) (string, error) {
	return mobileapi.RenderWarpProfile(params.Credentials, params.CampusTargets)
}
