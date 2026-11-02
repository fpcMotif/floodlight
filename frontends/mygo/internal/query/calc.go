// Package query recognizes the queries that name their own answer: an
// arithmetic expression, a unit conversion, a web address, a keyword engine.
// It also holds the search mode transitions. Everything here is pure: no
// files, no network, no UI, so the parity fixtures run it headless.
package query

import (
	"math"
	"strconv"
	"strings"
)

// Evaluate answers an arithmetic expression the way the Swift Calculator
// does: + - * / % ^ and parentheses, × ÷ − accepted, commas ignored. It
// reports false for anything that is not one, including a bare number, which
// is a search term, not a sum.
func Evaluate(source string) (float64, bool) {
	if source == "" || !strings.ContainsAny(source, "+-*/%^()×÷−") {
		return 0, false
	}
	s := strings.NewReplacer("×", "*", "÷", "/", "−", "-").Replace(source)
	s = strings.TrimSpace(s)
	if !strings.ContainsAny(s, "+-*/%^()") {
		return 0, false
	}
	for _, r := range s {
		if !('0' <= r && r <= '9') && !strings.ContainsRune(" \t\n.,+-*/%^()", r) {
			return 0, false
		}
	}
	p := parser{src: strings.ReplaceAll(s, ",", "")}
	v, ok := p.expr()
	if !ok || !p.atEnd() || math.IsInf(v, 0) || math.IsNaN(v) {
		return 0, false
	}
	return v, true
}

// FormatNumber writes v as the Swift app's decimal NumberFormatter does in
// an English locale: grouped thousands, at most ten fraction digits.
func FormatNumber(v float64) string {
	s := strconv.FormatFloat(v, 'f', 10, 64)
	s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	if s == "-0" {
		s = "0"
	}
	neg := strings.HasPrefix(s, "-")
	s = strings.TrimPrefix(s, "-")
	whole, frac, _ := strings.Cut(s, ".")
	var b strings.Builder
	if neg {
		b.WriteByte('-')
	}
	for i, r := range whole {
		if i > 0 && (len(whole)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(r)
	}
	if frac != "" {
		b.WriteByte('.')
		b.WriteString(frac)
	}
	return b.String()
}

type parser struct {
	src string
	i   int
}

func (p *parser) skip() {
	for p.i < len(p.src) && strings.IndexByte(" \t\n", p.src[p.i]) >= 0 {
		p.i++
	}
}

func (p *parser) atEnd() bool { p.skip(); return p.i == len(p.src) }

func (p *parser) eat(c byte) bool {
	p.skip()
	if p.i < len(p.src) && p.src[p.i] == c {
		p.i++
		return true
	}
	return false
}

func (p *parser) expr() (float64, bool) {
	v, ok := p.term()
	for ok {
		switch {
		case p.eat('+'):
			var r float64
			r, ok = p.term()
			v += r
		case p.eat('-'):
			var r float64
			r, ok = p.term()
			v -= r
		default:
			return v, true
		}
	}
	return 0, false
}

func (p *parser) term() (float64, bool) {
	v, ok := p.power()
	for ok {
		switch {
		case p.eat('*'):
			var r float64
			r, ok = p.power()
			v *= r
		case p.eat('/'):
			var r float64
			r, ok = p.power()
			if r == 0 {
				return 0, false
			}
			v /= r
		case p.eat('%'):
			var r float64
			r, ok = p.power()
			if r == 0 {
				return 0, false
			}
			v = math.Mod(v, r)
		default:
			return v, true
		}
	}
	return 0, false
}

// power is right-associative, so 2^3^2 is 2^9.
func (p *parser) power() (float64, bool) {
	v, ok := p.unary()
	if !ok {
		return 0, false
	}
	if p.eat('^') {
		e, ok := p.power()
		if !ok {
			return 0, false
		}
		v = math.Pow(v, e)
	}
	return v, true
}

func (p *parser) unary() (float64, bool) {
	if p.eat('-') {
		v, ok := p.unary()
		return -v, ok
	}
	if p.eat('+') {
		return p.unary()
	}
	if p.eat('(') {
		v, ok := p.expr()
		if !ok || !p.eat(')') {
			return 0, false
		}
		return v, true
	}
	return p.number()
}

func (p *parser) number() (float64, bool) {
	p.skip()
	start, dot := p.i, false
	for p.i < len(p.src) {
		c := p.src[p.i]
		if '0' <= c && c <= '9' {
			p.i++
		} else if c == '.' && !dot {
			dot = true
			p.i++
		} else {
			break
		}
	}
	if p.i == start {
		return 0, false
	}
	v, err := strconv.ParseFloat(p.src[start:p.i], 64)
	return v, err == nil
}
