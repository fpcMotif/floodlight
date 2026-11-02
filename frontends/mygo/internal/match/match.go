// Package match scores a name against a query the way the Zig core does
// (core/src/match.zig): fzf v1, a forward pass to the first full match and a
// backward pass to its tightest start, then only that window is scored.
//
// Apps and System Settings are scored here, in Go, because they are not in
// the file index. Porting the core's matcher instead of writing a new one is
// what keeps an app and a file that match equally well on the same scale, so
// the app bonus alone decides between them.
package match

const (
	scoreMatch       = 16
	bonusBoundary    = 8
	bonusNameStart   = 12
	bonusCamel       = 7
	bonusConsecutive = 5
	bonusInName      = 3
	penaltyGapStart  = 3
	penaltyGapExtend = 1
	bonusExactName   = 120
	bonusNamePrefix  = 40
)

func lower(c byte) byte {
	if 'A' <= c && c <= 'Z' {
		return c + 'a' - 'A'
	}
	return c
}

func isUpper(c byte) bool { return 'A' <= c && c <= 'Z' }
func isLower(c byte) bool { return 'a' <= c && c <= 'z' }

func isSeparator(c byte) bool {
	switch c {
	case '/', '-', '_', '.', ' ':
		return true
	}
	return false
}

// Lower returns s with ASCII letters lowercased, the form Score wants its
// needle in.
func Lower(s string) string {
	b := []byte(s)
	for i := range b {
		b[i] = lower(b[i])
	}
	return string(b)
}

// Score rates needle against hay, or reports false when needle is not a
// subsequence of it. needle must be lowercase. nameStart is where the last
// path component begins in hay, 0 when hay is a name.
func Score(hay, needle string, nameStart int) (int, bool) {
	if len(needle) == 0 {
		return 0, true
	}
	if len(needle) > len(hay) {
		return 0, false
	}
	j, end := 0, -1
	for i := 0; i < len(hay); i++ {
		if lower(hay[i]) == needle[j] {
			j++
			if j == len(needle) {
				end = i
				break
			}
		}
	}
	if end < 0 {
		return 0, false
	}

	// Walk back from the end so the window starts as late as it can: "abc"
	// in "a_xx_abc" scores the tight "abc", not the spread one.
	start := end
	j = len(needle)
	for i := end; i >= 0; i-- {
		if lower(hay[i]) == needle[j-1] {
			j--
			if j == 0 {
				start = i
				break
			}
		}
	}

	total, prev := 0, -1
	j = 0
	for k := start; k <= end; k++ {
		c := hay[k]
		if lower(c) != needle[j] {
			continue
		}
		bonus := 0
		switch {
		case k == nameStart:
			bonus = bonusNameStart
		case k == 0 || isSeparator(hay[k-1]):
			bonus = bonusBoundary
		case isUpper(c) && isLower(hay[k-1]):
			bonus = bonusCamel
		}
		if j == 0 {
			bonus *= 2
		}
		s := scoreMatch + bonus
		if k >= nameStart {
			s += bonusInName
		}
		if prev >= 0 {
			if gap := k - prev - 1; gap == 0 {
				s += bonusConsecutive
			} else {
				s -= penaltyGapStart + (min(gap, 32)-1)*penaltyGapExtend
			}
		}
		total += s
		prev = k
		j++
		if j == len(needle) {
			break
		}
	}

	name := hay[nameStart:]
	if len(name) >= len(needle) && hasPrefixFold(name, needle) {
		if len(name) == len(needle) || name[len(needle)] == '.' {
			total += bonusExactName
		} else {
			total += bonusNamePrefix
		}
	}
	return total, true
}

func hasPrefixFold(hay, needle string) bool {
	for i := 0; i < len(needle); i++ {
		if lower(hay[i]) != needle[i] {
			return false
		}
	}
	return true
}
