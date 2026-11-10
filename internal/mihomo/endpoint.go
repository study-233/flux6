package mihomo

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net"
	"strings"

	"github.com/yourname/freev6/internal/publisher"
)

// 校园门户仅用来选择仓库中的公开配置文件；摘要不是访问控制或加密。
const (
	cloudSlugSalt   = "freev6:campus:v1:"
	cloudSlugOffset = 7
	cloudSlugLength = 16
)

// NormalizePortalHost 把用户输入折叠成裸主机名：容忍粘贴整条 URL、
// 带端口、带路径、大小写、首尾空白。
func NormalizePortalHost(raw string) (string, error) {
	value := strings.ToLower(strings.TrimSpace(raw))
	if value == "" {
		return "", fmt.Errorf("校园网登录页地址为空")
	}
	for _, prefix := range []string{"https://", "http://"} {
		value = strings.TrimPrefix(value, prefix)
	}
	if cut := strings.IndexAny(value, "/?#"); cut >= 0 {
		value = value[:cut]
	}
	if host, _, err := net.SplitHostPort(value); err == nil {
		value = host
	}
	value = strings.TrimSuffix(value, ".")
	if value == "" {
		return "", fmt.Errorf("校园网登录页地址无法解析")
	}
	// IPv4 字面量与域名都接受；纯 IPv6 字面量不作为门户地址（不在本场景内）。
	if net.ParseIP(value) == nil && !validDomain(value) {
		return "", fmt.Errorf("不是合法的 IP 或域名: %q", strings.TrimSpace(raw))
	}
	return value, nil
}

// CloudSlug 由门户地址派生公开配置文件名。
func CloudSlug(portalHost string) (string, error) {
	host, err := NormalizePortalHost(portalHost)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256([]byte(cloudSlugSalt + host))
	full := hex.EncodeToString(sum[:])
	return full[cloudSlugOffset : cloudSlugOffset+cloudSlugLength], nil
}

// CloudProfileURL 返回派生出的配置入口地址。
func CloudProfileURL(portalHost string) (string, error) {
	slug, err := CloudSlug(portalHost)
	if err != nil {
		return "", err
	}
	return publisher.ProfilesURL + slug + ".yaml", nil
}
