//! A port of `core/src/match.zig`, so applications rank by the same rules as
//! files. The core's C ABI only searches its own index; an app list of a few
//! hundred names is cheaper to score here than to round-trip through a file.
//!
//! Keep the constants and both passes in step with the Zig source. The tests
//! are the Zig tests, case for case.

const SCORE_MATCH: i32 = 16;
const BONUS_BOUNDARY: i32 = 8;
const BONUS_NAME_START: i32 = 12;
const BONUS_CAMEL: i32 = 7;
const BONUS_CONSECUTIVE: i32 = 5;
const BONUS_IN_NAME: i32 = 3;
const PENALTY_GAP_START: i32 = 3;
const PENALTY_GAP_EXTEND: i32 = 1;
const BONUS_EXACT_NAME: i32 = 120;
const BONUS_NAME_PREFIX: i32 = 40;

fn is_separator(c: u8) -> bool {
    matches!(c, b'/' | b'-' | b'_' | b'.' | b' ')
}

fn starts_with_fold(hay: &[u8], needle: &[u8]) -> bool {
    hay.len() >= needle.len() && hay.iter().zip(needle).all(|(h, n)| h.to_ascii_lowercase() == *n)
}

/// `needle` must already be lowercase. `name_start` is where the last path
/// component begins in `hay` (0 when `hay` is the name itself).
pub fn score(hay: &[u8], needle: &[u8], name_start: usize) -> Option<i32> {
    if needle.is_empty() {
        return Some(0);
    }
    if needle.len() > hay.len() {
        return None;
    }

    let mut j = 0;
    let mut end = None;
    for (i, c) in hay.iter().enumerate() {
        if c.to_ascii_lowercase() == needle[j] {
            j += 1;
            if j == needle.len() {
                end = Some(i);
                break;
            }
        }
    }
    let end = end?;

    // Walk back from the end so the window starts as late as it can: "abc"
    // in "a_xx_abc" scores the tight "abc", not the spread one.
    let mut start = end;
    j = needle.len();
    for i in (0..=end).rev() {
        if hay[i].to_ascii_lowercase() == needle[j - 1] {
            j -= 1;
            if j == 0 {
                start = i;
                break;
            }
        }
    }

    let mut total = 0;
    let mut prev_match: Option<usize> = None;
    j = 0;
    for k in start..=end {
        let c = hay[k];
        if c.to_ascii_lowercase() != needle[j] {
            continue;
        }
        let mut bonus = if k == name_start {
            BONUS_NAME_START
        } else if k == 0 || is_separator(hay[k - 1]) {
            BONUS_BOUNDARY
        } else if c.is_ascii_uppercase() && hay[k - 1].is_ascii_lowercase() {
            BONUS_CAMEL
        } else {
            0
        };
        if j == 0 {
            bonus *= 2;
        }
        let mut s = SCORE_MATCH + bonus;
        if k >= name_start {
            s += BONUS_IN_NAME;
        }
        if let Some(p) = prev_match {
            let gap = k - p - 1;
            if gap == 0 {
                s += BONUS_CONSECUTIVE;
            } else {
                let g = gap.min(32) as i32;
                s -= PENALTY_GAP_START + (g - 1) * PENALTY_GAP_EXTEND;
            }
        }
        total += s;
        prev_match = Some(k);
        j += 1;
        if j == needle.len() {
            break;
        }
    }

    let name = &hay[name_start..];
    if starts_with_fold(name, needle) {
        total += if name.len() == needle.len() || name[needle.len()] == b'.' {
            BONUS_EXACT_NAME
        } else {
            BONUS_NAME_PREFIX
        };
    }
    Some(total)
}

#[cfg(test)]
mod tests {
    use super::score;

    fn s(hay: &str, needle: &str, name_start: usize) -> Option<i32> {
        score(hay.as_bytes(), needle.as_bytes(), name_start)
    }

    #[test]
    fn subsequence_required() {
        assert!(s("readme.md", "rdm", 0).is_some());
        assert!(s("readme.md", "xyz", 0).is_none());
        assert!(s("ab", "abc", 0).is_none());
    }

    #[test]
    fn case_insensitive() {
        assert!(s("ReadMe.MD", "readme", 0).is_some());
    }

    #[test]
    fn exact_name_beats_prefix_beats_scatter() {
        let exact = s("notes.txt", "notes", 0).unwrap();
        let prefix = s("notesbook.txt", "notes", 0).unwrap();
        let scatter = s("n_o_t_e_s.txt", "notes", 0).unwrap();
        assert!(exact > prefix);
        assert!(prefix > scatter);
    }

    #[test]
    fn match_in_name_beats_match_in_directory() {
        let in_name = s("src/budget.xlsx", "budget", 4).unwrap();
        let in_dir = s("budget/q3.xlsx", "budget", 7).unwrap();
        assert!(in_name > in_dir);
    }

    #[test]
    fn consecutive_beats_scattered() {
        assert!(s("xxabcxx", "abc", 0).unwrap() > s("xaxbxcx", "abc", 0).unwrap());
    }

    #[test]
    fn backward_pass_tightens_the_window() {
        assert_eq!(s("axxxxabc", "abc", 0), s("xxxxxabc", "abc", 0));
    }

    #[test]
    fn word_boundary_beats_mid_word() {
        assert!(s("my-app", "app", 0).unwrap() > s("mapping", "app", 0).unwrap());
    }
}
