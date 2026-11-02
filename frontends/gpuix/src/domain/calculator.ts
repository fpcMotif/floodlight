/**
 * Inline answers: arithmetic, ported from the Swift `Calculator`, and unit
 * conversions (`10 km to mi`, `72 f in c`). Pure, so the parity fixtures
 * check it headless.
 */

class Parser {
  private i = 0;
  constructor(private readonly s: string) {}

  atEnd(): boolean {
    this.skip();
    return this.i === this.s.length;
  }

  private skip(): void {
    while (this.i < this.s.length && this.s.charCodeAt(this.i) === 32) this.i++;
  }

  private consume(ch: string): boolean {
    this.skip();
    if (this.i < this.s.length && this.s.charAt(this.i) === ch) {
      this.i++;
      return true;
    }
    return false;
  }

  /** NaN stands for "no value": the Swift parser's nil. */
  expression(): number {
    let value = this.term();
    while (!isNaN(value)) {
      if (this.consume("+")) value = value + this.term();
      else if (this.consume("-")) value = value - this.term();
      else return value;
    }
    return NaN;
  }

  private term(): number {
    let value = this.power();
    while (!isNaN(value)) {
      if (this.consume("*")) {
        value = value * this.power();
      } else if (this.consume("/")) {
        const rhs = this.power();
        if (rhs === 0) return NaN;
        value = value / rhs;
      } else if (this.consume("%")) {
        const rhs = this.power();
        if (rhs === 0) return NaN;
        value = value % rhs;
      } else {
        return value;
      }
    }
    return NaN;
  }

  private power(): number {
    const value = this.unary();
    if (isNaN(value)) return NaN;
    if (this.consume("^")) return Math.pow(value, this.power());
    return value;
  }

  private unary(): number {
    if (this.consume("-")) return -this.unary();
    if (this.consume("+")) return this.unary();
    return this.primary();
  }

  private primary(): number {
    if (this.consume("(")) {
      const value = this.expression();
      if (isNaN(value) || !this.consume(")")) return NaN;
      return value;
    }
    return this.number();
  }

  private number(): number {
    this.skip();
    const start = this.i;
    let dot = false;
    while (this.i < this.s.length) {
      const c = this.s.charCodeAt(this.i);
      if (c >= 48 && c <= 57) this.i++;
      else if (c === 46 && !dot) {
        dot = true;
        this.i++;
      } else break;
    }
    if (this.i === start) return NaN;
    return parseFloat(this.s.slice(start, this.i));
  }
}

function isExpressionChar(c: string): boolean {
  return ".,+-*/%^() ".indexOf(c) >= 0 || (c >= "0" && c <= "9");
}

/** The value of an arithmetic query, or NaN when it is not one. */
export function evaluate(source: string): number {
  if (source.length === 0) return NaN;
  const normalized = source.split("×").join("*").split("÷").join("/").split("−").join("-").trim();
  let operator = false;
  for (const c of normalized) {
    if (!isExpressionChar(c)) return NaN;
    if ("+-*/%^()".indexOf(c) >= 0) operator = true;
  }
  if (!operator) return NaN;
  const parser = new Parser(normalized.split(",").join(""));
  const value = parser.expression();
  if (isNaN(value) || !parser.atEnd() || !isFinite(value)) return NaN;
  return value;
}

// ---- unit conversions ------------------------------------------------------

class Unit {
  constructor(
    readonly names: string[],
    /** Its dimension: units convert only within one. */
    readonly dimension: string,
    /** Multiplier to the dimension's base unit. Temperature uses `offset`. */
    readonly factor: number,
    readonly offset: number,
    readonly symbol: string,
  ) {}
}

const UNITS: Unit[] = [
  new Unit(["mm", "millimeter", "millimeters"], "length", 0.001, 0, "mm"),
  new Unit(["cm", "centimeter", "centimeters"], "length", 0.01, 0, "cm"),
  new Unit(["m", "meter", "meters", "metre", "metres"], "length", 1, 0, "m"),
  new Unit(["km", "kilometer", "kilometers"], "length", 1000, 0, "km"),
  new Unit(["in", "inch", "inches"], "length", 0.0254, 0, "in"),
  new Unit(["ft", "foot", "feet"], "length", 0.3048, 0, "ft"),
  new Unit(["yd", "yard", "yards"], "length", 0.9144, 0, "yd"),
  new Unit(["mi", "mile", "miles"], "length", 1609.344, 0, "mi"),
  new Unit(["mg", "milligram", "milligrams"], "mass", 0.001, 0, "mg"),
  new Unit(["g", "gram", "grams"], "mass", 1, 0, "g"),
  new Unit(["kg", "kilogram", "kilograms"], "mass", 1000, 0, "kg"),
  new Unit(["oz", "ounce", "ounces"], "mass", 28.349523125, 0, "oz"),
  new Unit(["lb", "lbs", "pound", "pounds"], "mass", 453.59237, 0, "lb"),
  new Unit(["ml", "milliliter", "milliliters"], "volume", 0.001, 0, "mL"),
  new Unit(["l", "liter", "liters", "litre", "litres"], "volume", 1, 0, "L"),
  new Unit(["gal", "gallon", "gallons"], "volume", 3.785411784, 0, "gal"),
  new Unit(["c", "°c", "celsius"], "temperature", 1, 0, "°C"),
  new Unit(["f", "°f", "fahrenheit"], "temperature", 5 / 9, -32, "°F"),
  new Unit(["k", "kelvin"], "temperature", 1, -273.15, "K"),
  new Unit(["b", "byte", "bytes"], "data", 1, 0, "B"),
  new Unit(["kb", "kilobyte", "kilobytes"], "data", 1e3, 0, "KB"),
  new Unit(["mb", "megabyte", "megabytes"], "data", 1e6, 0, "MB"),
  new Unit(["gb", "gigabyte", "gigabytes"], "data", 1e9, 0, "GB"),
  new Unit(["tb", "terabyte", "terabytes"], "data", 1e12, 0, "TB"),
];

function unitNamed(name: string): Unit | null {
  const key = name.toLowerCase();
  for (const unit of UNITS) {
    if (unit.names.indexOf(key) >= 0) return unit;
  }
  return null;
}

export class Conversion {
  constructor(
    readonly value: number,
    readonly symbol: string,
  ) {}
}

function toBase(value: number, unit: Unit): number {
  return (value + unit.offset) * unit.factor;
}

function fromBase(value: number, unit: Unit): number {
  return value / unit.factor - unit.offset;
}

/** `10 km to mi` → 6.2137… mi; null for anything else. */
export function convert(source: string): Conversion | null {
  const words: string[] = [];
  for (const w of source.trim().split(" ")) if (w.length > 0) words.push(w);
  if (words.length < 3) return null;
  // `10km to mi` and `10 km to mi` both read; split a glued number off.
  let amount = words[0];
  let rest = words.slice(1);
  let m = 0;
  while (m < amount.length && "0123456789.-".indexOf(amount.charAt(m)) >= 0) m++;
  if (m === 0) return null;
  if (m < amount.length) {
    rest = [amount.slice(m)].concat(rest);
    amount = amount.slice(0, m);
  }
  if (rest.length !== 3) return null;
  const joiner = rest[1].toLowerCase();
  if (joiner !== "to" && joiner !== "in" && joiner !== "as") return null;
  const value = parseFloat(amount);
  const from = unitNamed(rest[0]);
  const to = unitNamed(rest[2]);
  if (isNaN(value) || from === null || to === null || from.dimension !== to.dimension) return null;
  const result = fromBase(toBase(value, from), to);
  return isFinite(result) ? new Conversion(result, to.symbol) : null;
}
