package query

import (
	"net/url"
	"strings"
)

// DirectLink is the web address a query names outright (`https://abd.com/x`,
// `x.com/abc`, a bare `abd.com`), ported from the Swift DirectLink.
type DirectLink struct {
	URL  string
	Host string // without www.
}

// knownGTLDs are the long top-level domains common enough to type without a
// scheme. Every two-letter label counts as a ccTLD; the Swift app accepts the
// same collisions (`readme.md`) for the same reason.
var knownGTLDs = map[string]bool{
	"app": true, "biz": true, "blog": true, "cloud": true, "com": true, "dev": true, "edu": true,
	"gov": true, "info": true, "int": true, "mil": true, "net": true, "news": true, "online": true,
	"org": true, "page": true, "shop": true, "site": true, "store": true, "tech": true, "xyz": true,
}

// Link reads q as a web address. The scheme allowlist and the userinfo
// rejection keep the field from opening a URL its title misdescribes; do not
// relax either for an edge case.
func Link(q string) (DirectLink, bool) {
	token := strings.TrimSpace(q)
	if token == "" || strings.ContainsAny(token, " \t\n") || token[0] == '/' || token[0] == '~' {
		return DirectLink{}, false
	}
	abs, rest := token, token
	scheme, hasScheme := schemeOf(token)
	if hasScheme {
		if !strings.EqualFold(scheme, "http") && !strings.EqualFold(scheme, "https") {
			return DirectLink{}, false
		}
		rest = strings.TrimPrefix(token[len(scheme)+1:], "//")
	} else {
		abs = "https://" + token
	}
	authority := rest
	if i := strings.IndexAny(rest, "/?#"); i >= 0 {
		authority = rest[:i]
	}
	if strings.Contains(authority, "@") {
		return DirectLink{}, false
	}
	if !hasScheme && !knownHost(authority) {
		return DirectLink{}, false
	}
	u, err := url.Parse(abs)
	if err != nil || u.Hostname() == "" {
		return DirectLink{}, false
	}
	return DirectLink{URL: u.String(), Host: strings.TrimPrefix(u.Hostname(), "www.")}, true
}

// schemeOf is RFC 3986's ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":".
// `a.com:8080` reads as a scheme and is rejected, as in the Swift app.
func schemeOf(token string) (string, bool) {
	if !isLetter(token[0]) {
		return "", false
	}
	for i := 1; i < len(token); i++ {
		c := token[i]
		if c == ':' {
			return token[:i], true
		}
		if !isLetter(c) && !('0' <= c && c <= '9') && c != '+' && c != '-' && c != '.' {
			return "", false
		}
	}
	return "", false
}

func knownHost(authority string) bool {
	dot := strings.LastIndexByte(authority, '.')
	if dot <= 0 || strings.Contains(authority, "..") {
		return false
	}
	tld := authority[dot+1:]
	if tld == "" {
		return false
	}
	for i := 0; i < len(tld); i++ {
		if !isLetter(tld[i]) {
			return false
		}
	}
	return len(tld) == 2 || knownGTLDs[strings.ToLower(tld)]
}

func isLetter(c byte) bool { return 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' }
