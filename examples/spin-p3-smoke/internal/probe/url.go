package probe

import (
	"fmt"
	"net/url"
)

func NormalizeMockURL(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil || u.User != nil || u.Scheme != "http" || u.Hostname() != "127.0.0.1" || u.Port() != "18080" {
		return "", fmt.Errorf("invalid probe destination")
	}
	if u.Path == "" {
		u.Path = "/"
	}
	if u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("probe destination must not include query or fragment")
	}
	return u.String(), nil
}
