/** The self-test's assertions, shared by the unit checks and the parity runner. */

export class Tally {
  static checks = 0;
  static failures = 0;
}

export function check(ok: boolean, what: string): void {
  Tally.checks++;
  if (!ok) {
    Tally.failures++;
    console.error("FAIL: " + what);
  }
}

export function eq(actual: string, expected: string, what: string): void {
  check(
    actual === expected,
    what + "\n  expected: " + JSON.stringify(expected) + "\n  actual:   " + JSON.stringify(actual),
  );
}

export function eqn(actual: number, expected: number, what: string): void {
  eq(String(actual), String(expected), what);
}
