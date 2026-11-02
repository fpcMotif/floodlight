package query

import (
	"cmp"
	"slices"
	"strings"

	"github.com/fpcMotif/floodlight/frontends/mygo/internal/match"
)

// Setting is a System Settings pane a query can open.
type Setting struct {
	Name     string
	Keywords string // space-separated; a query matching one is a hit too
	Pane     string
}

// URL opens the pane.
func (s Setting) URL() string { return "x-apple.systempreferences:" + s.Pane }

// SettingHit is a matched pane, its score and why it matched.
type SettingHit struct {
	Setting
	Score    int
	Subtitle string // "System Settings", or "Matches: <keyword>"
}

// Settings is the Swift SystemCatalog's built-in list.
var Settings = []Setting{
	{"Accessibility", "voiceover zoom display motor hearing", "com.apple.Accessibility-Settings.extension"},
	{"Appearance", "light dark accent color sidebar icon size", "com.apple.Appearance-Settings.extension"},
	{"Apple Account", "icloud account profile", "AppleIDPrefPane"},
	{"Battery", "energy power low power mode health charging", "com.apple.Battery-Settings.extension"},
	{"Bluetooth", "devices headphones keyboard mouse", "com.apple.BluetoothSettings"},
	{"CDs & DVDs", "disc media optical", "com.apple.CD-DVD-Settings.extension"},
	{"Control Center", "menu bar widgets", "com.apple.ControlCenter-Settings.extension"},
	{"Date & Time", "clock timezone calendar", "com.apple.Date-Time-Settings.extension"},
	{"Desktop & Dock", "wallpaper mission control stage manager dock", "com.apple.Desktop-Settings.extension"},
	{"Displays", "monitor resolution brightness night shift", "com.apple.Displays-Settings.extension"},
	{"Focus", "do not disturb notifications schedule", "com.apple.Focus-Settings.extension"},
	{"General", "about software update storage airdrop handoff login items", "com.apple.systempreferences.GeneralSettings"},
	{"Game Center", "games profile friends multiplayer", "com.apple.Game-Center-Settings.extension"},
	{"Internet Accounts", "mail calendar contacts accounts", "com.apple.Internet-Accounts-Settings.extension"},
	{"Keyboard", "input text shortcuts dictation", "com.apple.Keyboard-Settings.extension"},
	{"Lock Screen", "password screensaver sleep", "com.apple.Lock-Screen-Settings.extension"},
	{"Login Items & Extensions", "startup background extensions", "com.apple.LoginItems-Settings.extension"},
	{"Mouse", "tracking scrolling click", "com.apple.Mouse-Settings.extension"},
	{"Network", "wifi ethernet vpn firewall", "com.apple.Network-Settings.extension"},
	{"Notifications", "alerts focus badges", "com.apple.Notifications-Settings.extension"},
	{"Printers & Scanners", "printer scanner print queue", "com.apple.Print-Scan-Settings.extension"},
	{"Privacy & Security", "location camera microphone full disk access", "com.apple.settings.PrivacySecurity.extension"},
	{"Profiles", "configuration management mdm", "com.apple.Profiles-Settings.extension"},
	{"Screen Saver", "wallpaper lock", "com.apple.ScreenSaver-Settings.extension"},
	{"Screen Time", "app limits downtime content privacy", "com.apple.Screen-Time-Settings.extension"},
	{"Sharing", "computer name screen file media remote login", "com.apple.Sharing-Settings.extension"},
	{"Siri & Spotlight", "assistant search indexing shortcuts", "com.apple.Siri-Settings.extension"},
	{"Software Update", "macos update automatic beta", "com.apple.Software-Update-Settings.extension"},
	{"Sound", "volume output input alert", "com.apple.Sound-Settings.extension"},
	{"Startup Disk", "boot volume disk", "com.apple.Startup-Disk-Settings.extension"},
	{"Storage", "disk space files optimize", "com.apple.settings.Storage"},
	{"Time Machine", "backup restore disk", "com.apple.Time-Machine-Settings.extension"},
	{"Touch ID & Password", "fingerprint authentication login password", "com.apple.Touch-ID-Settings.extension"},
	{"Trackpad", "gestures click scroll", "com.apple.Trackpad-Settings.extension"},
	{"Transfer or Reset", "migration erase reset assistant", "com.apple.Transfer-Reset-Settings.extension"},
	{"Users & Groups", "accounts login password", "com.apple.Users-Groups-Settings.extension"},
	{"Wallet & Apple Pay", "cards payments", "com.apple.WalletSettingsExtension"},
	{"Wallpaper", "desktop background picture", "com.apple.Wallpaper-Settings.extension"},
	{"Wi-Fi", "wifi wireless network hotspot", "com.apple.wifi-settings-extension"},
}

// MatchSettings scores each pane's name against q, then its keywords. A
// name match says "System Settings"; a keyword match names the keyword, so
// "wallpaper" reads as a reason to open Desktop & Dock. A keyword must start
// with the query: a scattered match inside "voiceover zoom display" is noise.
func MatchSettings(q string, limit int) []SettingHit {
	needle := match.Lower(strings.TrimSpace(q))
	if len(needle) < 2 || limit <= 0 {
		return nil
	}
	var hits []SettingHit
	for _, s := range Settings {
		if score, ok := match.Score(s.Name, needle, 0); ok && wordStart(s.Name, needle) {
			hits = append(hits, SettingHit{s, score, "System Settings"})
			continue
		}
		for _, k := range strings.Fields(s.Keywords) {
			if strings.HasPrefix(k, needle) {
				score, _ := match.Score(k, needle, 0)
				hits = append(hits, SettingHit{s, score / 2, "Matches: " + k})
				break
			}
		}
	}
	sortHits(hits)
	return hits[:min(limit, len(hits))]
}

// wordStart keeps a name hit to queries that begin some word of the name,
// "dis" for Displays, not "isp".
func wordStart(name, needle string) bool {
	for _, w := range strings.FieldsFunc(match.Lower(name), func(r rune) bool { return r == ' ' || r == '&' || r == '-' }) {
		if strings.HasPrefix(w, needle[:1]) {
			return true
		}
	}
	return false
}

func sortHits(h []SettingHit) {
	slices.SortStableFunc(h, func(a, b SettingHit) int { return cmp.Or(cmp.Compare(b.Score, a.Score), cmp.Compare(a.Name, b.Name)) })
}
