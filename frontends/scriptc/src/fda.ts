/**
 * The Full Disk Access grant, adapted to a terminal (#115). Without access
 * search keeps working and skips protected folders (#120); a notice row
 * offers the grant. Pure: the frontend feeds it probe results and the clock.
 */

export const FDA_GRANTED = 0;
/** Not granted: the notice row offers the grant. */
export const FDA_MISSING = 1;
/** System Settings is open at the list; polling for the grant. */
export const FDA_WAITING = 2;
/** Just granted: says so briefly while the index rebuilds. */
export const FDA_JUST_GRANTED = 3;

/** How long the granted state stays on screen. */
export const GRANTED_NOTICE_S = 3;
export const POLL_MS = 1000;

export const FDA_SETTINGS_URL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles";

export class FdaFlow {
  state = FDA_GRANTED;
  private grantedAt = 0;

  /** The first probe: 1 granted, 0 missing, -1 unknown (treated as granted). */
  start(probe: number): void {
    this.state = probe === 0 ? FDA_MISSING : FDA_GRANTED;
  }

  /** The user asked to grant: the frontend opens Settings and reveals the app. */
  beginGrant(): boolean {
    if (this.state !== FDA_MISSING && this.state !== FDA_WAITING) return false;
    this.state = FDA_WAITING;
    return true;
  }

  /** True while the frontend should keep probing. */
  polling(): boolean {
    return this.state === FDA_MISSING || this.state === FDA_WAITING || this.state === FDA_JUST_GRANTED;
  }

  /** A probe result at `now` seconds. True exactly once: when the grant lands
   * and the index should be rebuilt to include the protected folders. */
  tick(probe: number, now: number): boolean {
    if (this.state === FDA_JUST_GRANTED) {
      if (now - this.grantedAt >= GRANTED_NOTICE_S) this.state = FDA_GRANTED;
      return false;
    }
    if ((this.state === FDA_MISSING || this.state === FDA_WAITING) && probe === 1) {
      this.state = FDA_JUST_GRANTED;
      this.grantedAt = now;
      return true;
    }
    return false;
  }

  notice(hostName: string): string {
    if (this.state === FDA_MISSING) return "Full Disk Access is off, so protected folders are skipped. ^G grants it.";
    if (this.state === FDA_WAITING) {
      return "Drag " + (hostName.length > 0 ? hostName : "your terminal") + " into the Full Disk Access list…";
    }
    if (this.state === FDA_JUST_GRANTED) return "Full Disk Access granted. Reindexing…";
    return "";
  }
}
