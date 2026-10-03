import 'package:flutter_test/flutter_test.dart';
import 'package:swiftremote/ledger_db/sqlite_text.dart';

/// SQLite folded the 26 ASCII letters and nothing else; these hold the
/// helpers that stand in for its UPPER, LOWER, COLLATE NOCASE, BINARY and LIKE
/// to that.
void main() {
  group('asciiUpper and asciiLower', () {
    test('fold the 26 ASCII letters only', () {
      expect(asciiUpper('Power Off 9'), 'POWER OFF 9');
      expect(asciiLower('Power OFF 9'), 'power off 9');
      // Not Dart's toUpperCase: no é -> É, no dotless i -> I.
      expect(asciiUpper('straße é ı ǆ'), 'STRAßE é ı ǆ');
      expect(asciiLower('É İ Σ'), 'É İ Σ');
      expect('é'.toUpperCase(), isNot(asciiUpper('é')));
      expect('É'.toLowerCase(), isNot(asciiLower('É')));
    });

    test('leave a string with nothing to fold as it is', () {
      const String s = 'ABC 123 !_%';
      expect(identical(asciiUpper(s), s), isTrue);
      expect(identical(asciiLower('abc 123'), 'abc 123'), isTrue);
    });
  });

  group('compareBinary', () {
    test('orders by code point, as the UTF-8 bytes of SQLite do', () {
      expect(compareBinary('a', 'b'), lessThan(0));
      expect(compareBinary('b', 'a'), greaterThan(0));
      expect(compareBinary('abc', 'abc'), 0);
      expect(compareBinary('ab', 'abc'), lessThan(0));
      // `[`, `_` and the backtick sort after the capitals and before the
      // lower-case letters in ASCII.
      expect(compareBinary('Z', '_'), lessThan(0));
      expect(compareBinary('_', 'a'), lessThan(0));
    });

    test('puts a character outside the BMP after one from E000-FFFF', () {
      const String emoji = '\u{1F600}'; // a surrogate pair in UTF-16
      const String fullwidth = 'Ａ'; // FULLWIDTH LATIN CAPITAL LETTER A
      // Dart's own comparison puts the surrogate pair first; SQLite does not.
      expect(emoji.compareTo(fullwidth), lessThan(0));
      expect(compareBinary(emoji, fullwidth), greaterThan(0));
      expect(compareBinary(fullwidth, emoji), lessThan(0));
      expect(compareBinary('\u{1F600}', '\u{1F601}'), lessThan(0));
      expect(compareBinary('퟿', emoji), lessThan(0));
    });
  });

  test('compareNoCase folds ASCII before it compares', () {
    expect(compareNoCase('a', 'B'), lessThan(0));
    expect(compareNoCase('B', 'a'), greaterThan(0));
    expect(compareNoCase('SONY', 'sony'), 0);
    // `_` (0x5F) sorts after the capitals but before the folded letters only
    // under UPPER; NOCASE folds to lower case, where it sorts before `a`.
    expect(compareNoCase('A_B', 'AB'), lessThan(0));
    expect(compareNoCase('A_B', 'Ab'), lessThan(0));
    expect(compareBinary(asciiUpper('A_B'), asciiUpper('Ab')), greaterThan(0));
    // Non-ASCII letters are not folded.
    expect(compareNoCase('é', 'É'), isNot(0));
  });

  group('LIKE', () {
    test('a substring search ignores ASCII case only', () {
      expect(likeContains('Power Toggle', 'power'), isTrue);
      expect(likeContains('Power Toggle', 'WER T'), isTrue);
      expect(likeContains('Power Toggle', 'power off'), isFalse);
      expect(likeContains('anything', ''), isTrue);
      expect(likeContains('Ünder', 'ünder'), isFalse);
      expect(likeContains('Ünder', 'Ünder'), isTrue);
      // The needle is a plain string: % and _ stand for themselves once
      // escaped, which is what the old queries did.
      expect(likeContains('50%_off', '%_'), isTrue);
      expect(likeContains('5000', '%'), isFalse);
    });

    test('escapeLike writes a term for LIKE ... ESCAPE', () {
      expect(escapeLike(r'50%_\x'), r'50\%\_\\x');
      expect(escapeLike('plain'), 'plain');
    });

    test('without ESCAPE, % and _ are wildcards and a backslash is a letter',
        () {
      expect(sqliteLike('A%', 'a9'), isTrue);
      expect(sqliteLike('A%', 'B9'), isFalse);
      expect(sqliteLike('%9', 'A9'), isTrue);
      expect(sqliteLike('%A%', 'xxAxx'), isTrue);
      expect(sqliteLike('A_9', 'AB9'), isTrue);
      expect(sqliteLike('A_9', 'A9'), isFalse);
      expect(sqliteLike('%', ''), isTrue);
      expect(sqliteLike('_', ''), isFalse);
      expect(sqliteLike('ab', 'AB'), isTrue);
      expect(sqliteLike('ab', 'ABC'), isFalse);
      expect(sqliteLike('%a%b%c%', 'xaxbxcx'), isTrue);
      expect(sqliteLike('%a%b%c%', 'xcxbxax'), isFalse);
      // The escaped form of a search term never matches a hexcode: its
      // backslash is a letter here.
      expect(sqliteLike('%${escapeLike('A_B')}%', 'A_B'), isFalse);
      expect(sqliteLike(r'%\_%', r'x\_y'), isTrue);
    });

    test('an underscore matches one character, a surrogate pair included', () {
      expect(sqliteLike('a_b', 'a\u{1F600}b'), isTrue);
      expect(sqliteLike('a__b', 'a\u{1F600}b'), isFalse);
    });

    test('é does not match É: only ASCII letters fold', () {
      expect(sqliteLike('é%', 'É1'), isFalse);
      expect(sqliteLike('é%', 'é1'), isTrue);
    });
  });

  test('protocolKey reduces a spelling to letters and digits', () {
    expect(protocolKey('RCA-38'), 'rca38');
    expect(protocolKey(' rca_38 '), 'rca38');
    expect(protocolKey('RCA 38'), 'rca38');
    expect(protocolKey('RECS80_L'), 'recs80l');
    expect(protocolKey('--'), '');
  });
}
