/** Number, size and date formats shared by the rows and the inspector. */

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** `1,234,567`: digits grouped in threes. */
export function groupDigits(digits: string): string {
  let out = "";
  for (let i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 === 0) out += ",";
    out += digits.charAt(i);
  }
  return out;
}

export function group(n: number): string {
  const sign = n < 0 ? "-" : "";
  return sign + groupDigits(String(Math.floor(Math.abs(n))));
}

/** Finder's file-size style: decimal units, more precision as they grow. */
export function formatBytes(bytes: number): string {
  if (bytes < 0) return "";
  if (bytes < 1000) return bytes === 1 ? "1 byte" : bytes + " bytes";
  if (bytes < 1e6) return Math.round(bytes / 1e3) + " KB";
  if (bytes < 1e9) return (bytes / 1e6).toFixed(1) + " MB";
  return (bytes / 1e9).toFixed(2) + " GB";
}

function sameDay(a: Date, b: Date): boolean {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

/** `Today`, `Yesterday`, or `3 Nov 2026`, in local time. */
export function formatDay(seconds: number, nowSeconds: number): string {
  if (seconds <= 0) return "";
  const then = new Date(seconds * 1000);
  const now = new Date(nowSeconds * 1000);
  if (sameDay(then, now)) return "Today";
  const yesterday = new Date((nowSeconds - 86400) * 1000);
  if (sameDay(then, yesterday)) return "Yesterday";
  return then.getDate() + " " + MONTHS[then.getMonth()] + " " + then.getFullYear();
}

/** The Swift board's age: `just now`, `5m`, `3h`, `2d`, `4mo`, `1y`. */
export function formatAge(seconds: number, nowSeconds: number): string {
  const elapsed = Math.max(0, Math.floor(nowSeconds - seconds));
  if (elapsed < 60) return "just now";
  const minutes = Math.floor(elapsed / 60);
  if (minutes < 60) return minutes + "m";
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return hours + "h";
  const days = Math.floor(hours / 24);
  if (days < 30) return days + "d";
  const months = Math.floor(days / 30);
  if (months < 12) return months + "mo";
  return Math.floor(days / 365) + "y";
}

/**
 * The Swift calculator's answer format: grouped thousands, up to ten
 * fraction digits, no trailing zeros.
 */
export function formatNumber(value: number): string {
  if (!isFinite(value)) return String(value);
  const negative = value < 0;
  const fixed = Math.abs(value).toFixed(10);
  const dot = fixed.indexOf(".");
  let whole = dot < 0 ? fixed : fixed.slice(0, dot);
  let fraction = dot < 0 ? "" : fixed.slice(dot + 1);
  while (fraction.length > 0 && fraction.charAt(fraction.length - 1) === "0") {
    fraction = fraction.slice(0, fraction.length - 1);
  }
  whole = groupDigits(whole);
  const body = fraction.length > 0 ? whole + "." + fraction : whole;
  return negative && body !== "0" ? "-" + body : body;
}
