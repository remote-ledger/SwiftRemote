/// The text rules SQLite applied to the old bundled IR database, written down
/// so that answering the same questions from files gives the same answers.
///
/// All of them are ASCII-only on purpose. SQLite folds the 26 ASCII letters
/// and nothing else in `UPPER`, `LOWER`, `COLLATE NOCASE` and `LIKE` (unless
/// built with ICU, which the old queries never relied on), so `é` and `É` are
/// different letters here exactly as they were there, and Dart's own
/// `toUpperCase`/`compareTo` must not be used where one of these is meant.
library;

/// SQLite's `UPPER`: `a`-`z` become `A`-`Z`, every other character is left as
/// it is.
String asciiUpper(String s) {
  for (int i = 0; i < s.length; i++) {
    final int u = s.codeUnitAt(i);
    if (u >= 0x61 && u <= 0x7A) return _mapAscii(s, i, -32);
  }
  return s;
}

/// SQLite's `LOWER`, and the fold of `COLLATE NOCASE`.
String asciiLower(String s) {
  for (int i = 0; i < s.length; i++) {
    final int u = s.codeUnitAt(i);
    if (u >= 0x41 && u <= 0x5A) return _mapAscii(s, i, 32);
  }
  return s;
}

String _mapAscii(String s, int from, int delta) {
  final List<int> units = s.codeUnits.toList(growable: false);
  final bool toUpper = delta < 0;
  for (int i = from; i < units.length; i++) {
    final int u = units[i];
    if (toUpper ? (u >= 0x61 && u <= 0x7A) : (u >= 0x41 && u <= 0x5A)) {
      units[i] = u + delta;
    }
  }
  return String.fromCharCodes(units);
}

/// SQLite's BINARY collation: the UTF-8 bytes compared one by one, which is
/// the order of the code points.
///
/// Dart compares UTF-16 code units, which agrees except where a character
/// outside the Basic Multilingual Plane (a surrogate pair, `D800`-`DFFF`) meets
/// one from `E000`-`FFFF`: in UTF-16 the pair sorts first, in code point order
/// it sorts last.
int compareBinary(String a, String b) {
  final int n = a.length < b.length ? a.length : b.length;
  for (int i = 0; i < n; i++) {
    final int x = a.codeUnitAt(i);
    final int y = b.codeUnitAt(i);
    if (x == y) continue;
    return _codePointOrder(x).compareTo(_codePointOrder(y));
  }
  return a.length.compareTo(b.length);
}

int _codePointOrder(int unit) {
  if (unit >= 0xE000) return unit - 0x800;
  if (unit >= 0xD800) return unit + 0x2000;
  return unit;
}

/// `COLLATE NOCASE`: ASCII letters folded to lower case, then BINARY.
int compareNoCase(String a, String b) =>
    compareBinary(asciiLower(a), asciiLower(b));

/// What `_escapeLike` did to a search term before it went into
/// `LIKE ... ESCAPE '\'`.
String escapeLike(String input) {
  return input
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');
}

/// `haystack LIKE '%needle%' ESCAPE '\'` once the needle has been escaped:
/// a plain substring test, ASCII letters compared without regard to case.
bool likeContains(String haystack, String needle) {
  if (needle.isEmpty) return true;
  return asciiLower(haystack).contains(asciiLower(needle));
}

/// `text LIKE pattern` with no ESCAPE clause: `%` stands for any run of
/// characters (including none), `_` for exactly one, and every other character,
/// a backslash included, for itself, ASCII letters without regard to case.
///
/// The old queries used this form for the hexcode half of a key search and for
/// the hex prefix, so a search term holding a `%`, an `_` or a backslash
/// behaved the way SQLite made it behave, and so it does here.
bool sqliteLike(String pattern, String text) {
  final String p = asciiLower(pattern);
  final String t = asciiLower(text);
  if (!p.contains('%') && !p.contains('_')) return p == t;

  // Wildcard matching with backtracking to the last `%`. `_` consumes one
  // character, which is two UTF-16 code units for a surrogate pair.
  int pi = 0;
  int ti = 0;
  int starP = -1;
  int starT = 0;
  while (ti < t.length) {
    if (pi < p.length && p.codeUnitAt(pi) == 0x25) {
      starP = pi++;
      starT = ti;
    } else if (pi < p.length && p.codeUnitAt(pi) == 0x5F) {
      pi++;
      ti += _charLength(t, ti);
    } else if (pi < p.length && p.codeUnitAt(pi) == t.codeUnitAt(ti)) {
      pi++;
      ti++;
    } else if (starP >= 0) {
      pi = starP + 1;
      starT += _charLength(t, starT);
      ti = starT;
    } else {
      return false;
    }
  }
  while (pi < p.length && p.codeUnitAt(pi) == 0x25) {
    pi++;
  }
  return pi == p.length;
}

int _charLength(String s, int i) {
  final int u = s.codeUnitAt(i);
  if (u >= 0xD800 && u <= 0xDBFF && i + 1 < s.length) {
    final int next = s.codeUnitAt(i + 1);
    if (next >= 0xDC00 && next <= 0xDFFF) return 2;
  }
  return 1;
}

/// The normalised protocol key the app compares protocols by: trimmed,
/// lower-cased, with everything that is not a letter or digit removed, so
/// `RCA-38`, `rca_38` and `RCA 38` are one protocol.
String protocolKey(String s) {
  return s.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}
