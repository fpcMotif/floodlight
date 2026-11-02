/**
 * System Settings panes as results, from the Swift `SystemCatalog` table.
 * A pane matches on its name with the core's scoring, or on a keyword
 * ("wifi", "full disk access") when every term starts one of its words.
 */
import { scoreAllTerms } from "./core-match";
import { fuzzyMatch } from "./match";
import { ACTION_OPEN, KIND_SETTING, Row } from "./row";

/** Below an app with the same score, above a file with the same score. */
export const SETTING_BONUS = 30;
const KEYWORD_SCORE_PER_TERM = 20;

class Pane {
  readonly words: string[];
  constructor(
    readonly name: string,
    keywords: string,
    readonly pane: string,
  ) {
    this.words = (name + " " + keywords).toLowerCase().split(" ");
  }
}

const PANES: Pane[] = [
  new Pane("Accessibility", "voiceover zoom display motor hearing", "com.apple.Accessibility-Settings.extension"),
  new Pane("Appearance", "light dark accent color sidebar icon size", "com.apple.Appearance-Settings.extension"),
  new Pane("Apple Account", "icloud account profile", "AppleIDPrefPane"),
  new Pane("Battery", "energy power low power mode health charging", "com.apple.Battery-Settings.extension"),
  new Pane("Bluetooth", "devices headphones keyboard mouse", "com.apple.BluetoothSettings"),
  new Pane("CDs & DVDs", "disc media optical", "com.apple.CD-DVD-Settings.extension"),
  new Pane("Control Center", "menu bar widgets", "com.apple.ControlCenter-Settings.extension"),
  new Pane("Date & Time", "clock timezone calendar", "com.apple.Date-Time-Settings.extension"),
  new Pane("Desktop & Dock", "wallpaper mission control stage manager dock", "com.apple.Desktop-Settings.extension"),
  new Pane("Displays", "monitor resolution brightness night shift", "com.apple.Displays-Settings.extension"),
  new Pane("Focus", "do not disturb notifications schedule", "com.apple.Focus-Settings.extension"),
  new Pane(
    "General",
    "about software update storage airdrop handoff login items",
    "com.apple.systempreferences.GeneralSettings",
  ),
  new Pane("Game Center", "games profile friends multiplayer", "com.apple.Game-Center-Settings.extension"),
  new Pane("Internet Accounts", "mail calendar contacts accounts", "com.apple.Internet-Accounts-Settings.extension"),
  new Pane("Keyboard", "input text shortcuts dictation", "com.apple.Keyboard-Settings.extension"),
  new Pane("Lock Screen", "password screensaver sleep", "com.apple.Lock-Screen-Settings.extension"),
  new Pane("Login Items & Extensions", "startup background extensions", "com.apple.LoginItems-Settings.extension"),
  new Pane("Mouse", "tracking scrolling click", "com.apple.Mouse-Settings.extension"),
  new Pane("Network", "wifi ethernet vpn firewall", "com.apple.Network-Settings.extension"),
  new Pane("Notifications", "alerts focus badges", "com.apple.Notifications-Settings.extension"),
  new Pane("Printers & Scanners", "printer scanner print queue", "com.apple.Print-Scan-Settings.extension"),
  new Pane(
    "Privacy & Security",
    "location camera microphone full disk access",
    "com.apple.settings.PrivacySecurity.extension",
  ),
  new Pane("Profiles", "configuration management mdm", "com.apple.Profiles-Settings.extension"),
  new Pane("Screen Saver", "wallpaper lock", "com.apple.ScreenSaver-Settings.extension"),
  new Pane("Screen Time", "app limits downtime content privacy", "com.apple.Screen-Time-Settings.extension"),
  new Pane("Sharing", "computer name screen file media remote login", "com.apple.Sharing-Settings.extension"),
  new Pane("Siri & Spotlight", "assistant search indexing shortcuts", "com.apple.Siri-Settings.extension"),
  new Pane("Software Update", "macos update automatic beta", "com.apple.Software-Update-Settings.extension"),
  new Pane("Sound", "volume output input alert", "com.apple.Sound-Settings.extension"),
  new Pane("Startup Disk", "boot volume disk", "com.apple.Startup-Disk-Settings.extension"),
  new Pane("Storage", "disk space files optimize", "com.apple.settings.Storage"),
  new Pane("Time Machine", "backup restore disk", "com.apple.Time-Machine-Settings.extension"),
  new Pane("Touch ID & Password", "fingerprint authentication login password", "com.apple.Touch-ID-Settings.extension"),
  new Pane("Trackpad", "gestures click scroll", "com.apple.Trackpad-Settings.extension"),
  new Pane("Transfer or Reset", "migration erase reset assistant", "com.apple.Transfer-Reset-Settings.extension"),
  new Pane("Users & Groups", "accounts login password", "com.apple.Users-Groups-Settings.extension"),
  new Pane("Wallet & Apple Pay", "cards payments", "com.apple.WalletSettingsExtension"),
  new Pane("Wallpaper", "desktop background picture", "com.apple.Wallpaper-Settings.extension"),
  new Pane("Wi-Fi", "wifi wireless network hotspot", "com.apple.wifi-settings-extension"),
];

function keywordScore(pane: Pane, terms: string[]): number {
  for (const term of terms) {
    let hit = false;
    for (const word of pane.words) {
      if (word.startsWith(term)) {
        hit = true;
        break;
      }
    }
    if (!hit) return -1;
  }
  return KEYWORD_SCORE_PER_TERM * terms.length;
}

export const SETTINGS_URL_PREFIX = "x-apple.systempreferences:";

export function settingRows(terms: string[]): Row[] {
  const rows: Row[] = [];
  if (terms.length === 0) return rows;
  const joined = terms.join("");
  for (const pane of PANES) {
    let score = scoreAllTerms(pane.name, terms);
    if (score < 0) score = keywordScore(pane, terms);
    if (score < 0) continue;
    const match = fuzzyMatch(pane.name, joined);
    rows.push(
      new Row(
        KIND_SETTING,
        "setting:" + pane.pane,
        pane.name,
        "System Settings",
        SETTINGS_URL_PREFIX + pane.pane,
        ACTION_OPEN,
        match === null ? [] : match.positions,
        score + SETTING_BONUS,
      ),
    );
  }
  return rows;
}
