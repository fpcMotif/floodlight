package query

import (
	"math"
	"strconv"
	"strings"
)

// A unit belongs to one dimension and converts to that dimension's base
// unit by factor, or, for temperature, by the offset as well.
type unit struct {
	dim    string
	factor float64 // base units per one of this unit
	offset float64 // added after scaling; temperature only
	symbol string  // how the answer names it
}

var units = func() map[string]unit {
	m := map[string]unit{}
	add := func(dim string, factor, offset float64, symbol string, names ...string) {
		for _, n := range names {
			m[n] = unit{dim, factor, offset, symbol}
		}
	}
	// Length, base metre.
	add("length", 0.001, 0, "mm", "mm", "millimeter", "millimeters", "millimetre", "millimetres")
	add("length", 0.01, 0, "cm", "cm", "centimeter", "centimeters", "centimetre", "centimetres")
	add("length", 1, 0, "m", "m", "meter", "meters", "metre", "metres")
	add("length", 1000, 0, "km", "km", "kilometer", "kilometers", "kilometre", "kilometres")
	add("length", 0.0254, 0, "in", "in", "inch", "inches")
	add("length", 0.3048, 0, "ft", "ft", "foot", "feet")
	add("length", 0.9144, 0, "yd", "yd", "yard", "yards")
	add("length", 1609.344, 0, "mi", "mi", "mile", "miles")
	// Mass, base gram.
	add("mass", 0.001, 0, "mg", "mg", "milligram", "milligrams")
	add("mass", 1, 0, "g", "g", "gram", "grams")
	add("mass", 1000, 0, "kg", "kg", "kilogram", "kilograms", "kilo", "kilos")
	add("mass", 28.349523125, 0, "oz", "oz", "ounce", "ounces")
	add("mass", 453.59237, 0, "lb", "lb", "lbs", "pound", "pounds")
	add("mass", 1e6, 0, "t", "tonne", "tonnes")
	// Volume, base litre.
	add("volume", 0.001, 0, "ml", "ml", "milliliter", "milliliters", "millilitre", "millilitres")
	add("volume", 1, 0, "l", "l", "liter", "liters", "litre", "litres")
	add("volume", 0.0295735295625, 0, "fl oz", "floz")
	add("volume", 0.2365882365, 0, "cup", "cup", "cups")
	add("volume", 3.785411784, 0, "gal", "gal", "gallon", "gallons")
	// Time, base second.
	add("time", 0.001, 0, "ms", "ms", "millisecond", "milliseconds")
	add("time", 1, 0, "s", "s", "sec", "secs", "second", "seconds")
	add("time", 60, 0, "min", "min", "mins", "minute", "minutes")
	add("time", 3600, 0, "h", "h", "hr", "hrs", "hour", "hours")
	add("time", 86400, 0, "d", "day", "days")
	add("time", 604800, 0, "wk", "wk", "week", "weeks")
	// Data, base byte, decimal prefixes as Finder counts.
	add("data", 1, 0, "B", "b", "byte", "bytes")
	add("data", 1e3, 0, "KB", "kb", "kilobyte", "kilobytes")
	add("data", 1e6, 0, "MB", "mb", "megabyte", "megabytes")
	add("data", 1e9, 0, "GB", "gb", "gigabyte", "gigabytes")
	add("data", 1e12, 0, "TB", "tb", "terabyte", "terabytes")
	add("data", 1<<10, 0, "KiB", "kib")
	add("data", 1<<20, 0, "MiB", "mib")
	add("data", 1<<30, 0, "GiB", "gib")
	// Speed, base metre per second.
	add("speed", 1/3.6, 0, "km/h", "km/h", "kmh", "kph")
	add("speed", 0.44704, 0, "mph", "mph")
	add("speed", 1, 0, "m/s", "m/s")
	// Temperature, base kelvin: K = value*factor + offset.
	add("temperature", 1, 273.15, "°C", "c", "°c", "celsius")
	add("temperature", 5.0/9, 459.67*5/9, "°F", "f", "°f", "fahrenheit")
	add("temperature", 1, 0, "K", "k", "kelvin")
	return m
}()

// Convert answers "10 km to mi", "72 f in c" or "1.5 gb as mb": a number,
// a unit, a joining word, a unit of the same dimension. It returns the
// answer with its unit symbol, or false.
func Convert(q string) (string, bool) {
	f := strings.Fields(strings.ToLower(q))
	// "10km to mi" is as common as "10 km to mi".
	if len(f) == 3 {
		if i := strings.IndexFunc(f[0], func(r rune) bool { return !('0' <= r && r <= '9' || r == '.' || r == '-') }); i > 0 {
			f = append([]string{f[0][:i], f[0][i:]}, f[1:]...)
		}
	}
	if len(f) != 4 || (f[2] != "to" && f[2] != "in" && f[2] != "as" && f[2] != "=") {
		return "", false
	}
	v, err := strconv.ParseFloat(strings.ReplaceAll(f[0], ",", ""), 64)
	if err != nil {
		return "", false
	}
	from, ok1 := units[f[1]]
	to, ok2 := units[f[3]]
	if !ok1 || !ok2 || from.dim != to.dim {
		return "", false
	}
	base := v*from.factor + from.offset
	out := (base - to.offset) / to.factor
	return FormatNumber(math.Round(out*1e4)/1e4) + " " + to.symbol, true
}
