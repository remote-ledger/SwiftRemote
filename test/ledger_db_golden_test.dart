import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftremote/ir_finder/ir_finder_models.dart';
import 'package:swiftremote/ir_finder/irblaster_db.dart';

import 'support/ledger_fixtures.dart';

/// The IR code database used to be a bundled sqlite, queried with SQL. These
/// tests hold the implementation that reads the Remote Ledger's files to what
/// that SQL answered, for a sample of queries written down in
/// test/fixtures/ledger_api/golden.json by tools/ledger_api_golden.py: the
/// same questions put to the old database, de-duplicated by (id, label,
/// hexcode, protocol) and restricted to the keys the ledger holds.

String _escape(String s) => s
    .replaceAll('\\', '\\\\')
    .replaceAll('\t', '\\t')
    .replaceAll('\n', '\\n')
    .replaceAll('\r', '\\r');

String _digest(Iterable<String> lines) =>
    sha256.convert(utf8.encode(lines.join('\n'))).toString();

String _digestStrings(List<String> values) => _digest(values.map(_escape));

String _digestRows(List<IrDbKeyCandidate> rows) => _digest(rows.map(
      (IrDbKeyCandidate r) =>
          '${r.id}\t${_escape(r.label ?? '')}\t${_escape(r.protocol)}\t${_escape(r.hexcode)}',
    ));

List<List<Object?>> _head(List<IrDbKeyCandidate> rows, int n) => rows
    .take(n)
    .map(
        (IrDbKeyCandidate r) => <Object?>[r.id, r.label, r.protocol, r.hexcode])
    .toList();

const int _all = 1 << 40;

void main() {
  late Map<String, dynamic> golden;
  late List<Map<String, dynamic>> cases;
  late IrBlasterDb db;
  late Directory dir;

  setUpAll(() async {
    golden = Map<String, dynamic>.from(
      jsonDecode(File('${ledgerFixtures.path}/golden.json').readAsStringSync())
          as Map,
    );
    cases = (golden['cases'] as List<dynamic>)
        .map((dynamic c) => Map<String, dynamic>.from(c as Map))
        .toList();
    dir = await tempCacheDir();
    db = IrBlasterDb.forTesting(fixtureLedgerDb(FakeLedgerServer(), dir));
  });

  tearDownAll(() async {
    await dir.delete(recursive: true);
  });

  Iterable<Map<String, dynamic>> casesFor(String fn) =>
      cases.where((Map<String, dynamic> c) => c['fn'] == fn);

  String describe(Map<String, dynamic> c) => jsonEncode(c['args']);

  void expectStringCase(
    List<String> failures,
    Map<String, dynamic> c,
    List<String> actual,
  ) {
    final List<String> head = (c['head'] as List<dynamic>).cast<String>();
    if (actual.length != c['count'] ||
        _digestStrings(actual) != c['sha'] ||
        !_listEquals(actual.take(head.length).toList(), head)) {
      failures.add(
        '${c['fn']} ${describe(c)}: expected ${c['count']} '
        '(${head.join(' | ')} ...), got ${actual.length} '
        '(${actual.take(head.length).join(' | ')} ...)',
      );
    }
  }

  test('the golden file is not empty and covers every query', () {
    expect(cases.length, greaterThan(1000));
    expect(
      cases.map((Map<String, dynamic> c) => c['fn']).toSet(),
      <String>{
        'listBrands',
        'listModelsDistinct',
        'listProtocolsFor',
        'listProtocolsForBrand',
        'fetchCandidateKeys',
      },
    );
  });

  test('listBrands answers as the old query did: NOCASE order, LIKE, protocol',
      () async {
    final List<String> failures = <String>[];
    for (final Map<String, dynamic> c in casesFor('listBrands')) {
      final Map<String, dynamic> a = c['args'] as Map<String, dynamic>;
      final List<String> got = await db.listBrands(
        search: a['search'] as String?,
        protocolId: a['protocol'] as String?,
        limit: _all,
      );
      expectStringCase(failures, c, got);
    }
    expect(failures, isEmpty, reason: failures.take(8).join('\n'));
  });

  test('listBrands pages by limit and offset', () async {
    final List<String> all = await db.listBrands(limit: _all);
    expect(all, hasLength(4902));
    expect(await db.listBrands(limit: 5, offset: 3), all.sublist(3, 8));
    expect(await db.listBrands(offset: 4900, limit: 60), all.sublist(4900));
    expect(await db.listBrands(offset: 5000), isEmpty);
    final List<String> paged = <String>[];
    for (int offset = 0;; offset += 60) {
      final List<String> page = await db.listBrands(limit: 60, offset: offset);
      if (page.isEmpty) break;
      paged.addAll(page);
    }
    expect(paged, all);
  });

  test('listModelsDistinct answers as the old queries did', () async {
    final List<String> failures = <String>[];
    for (final Map<String, dynamic> c in casesFor('listModelsDistinct')) {
      final Map<String, dynamic> a = c['args'] as Map<String, dynamic>;
      final List<String> got = await db.listModelsDistinct(
        brand: a['brand'] as String,
        search: a['search'] as String?,
        protocolId: a['protocol'] as String?,
        limit: _all,
      );
      expectStringCase(failures, c, got);
    }
    expect(failures, isEmpty, reason: failures.take(8).join('\n'));
  });

  test('listProtocolsForBrand and listProtocolsFor answer as the old joins did',
      () async {
    final List<String> failures = <String>[];
    for (final Map<String, dynamic> c in casesFor('listProtocolsForBrand')) {
      final Map<String, dynamic> a = c['args'] as Map<String, dynamic>;
      expectStringCase(
        failures,
        c,
        await db.listProtocolsForBrand(a['brand'] as String),
      );
    }
    for (final Map<String, dynamic> c in casesFor('listProtocolsFor')) {
      final Map<String, dynamic> a = c['args'] as Map<String, dynamic>;
      expectStringCase(
        failures,
        c,
        await db.listProtocolsFor(
          brand: a['brand'] as String,
          model: a['model'] as String,
        ),
      );
    }
    expect(failures, isEmpty, reason: failures.take(8).join('\n'));
  });

  test('fetchCandidateKeys answers as the old query did, once per key',
      () async {
    final List<String> failures = <String>[];
    int nonEmpty = 0;
    for (final Map<String, dynamic> c in casesFor('fetchCandidateKeys')) {
      final Map<String, dynamic> a = c['args'] as Map<String, dynamic>;
      final List<IrDbKeyCandidate> rows = await db.fetchCandidateKeys(
        brand: a['brand'] as String,
        model: a['model'] as String?,
        selectedProtocolId: a['protocol'] as String?,
        quickWinsFirst: a['quickWinsFirst'] as bool,
        hexPrefixUpper: a['hexPrefix'] as String?,
        search: a['search'] as String?,
        limit: _all,
      );
      final int count = await db.countCandidateKeys(
        brand: a['brand'] as String,
        model: a['model'] as String?,
        selectedProtocolId: a['protocol'] as String?,
        hexPrefixUpper: a['hexPrefix'] as String?,
        search: a['search'] as String?,
      );
      if (rows.isNotEmpty) nonEmpty++;
      final List<dynamic> head = c['head'] as List<dynamic>;
      final List<List<Object?>> gotHead = _head(rows, head.length);
      if (rows.length != c['count'] ||
          count != c['count'] ||
          _digestRows(rows) != c['sha'] ||
          jsonEncode(gotHead) != jsonEncode(head)) {
        failures.add(
          'fetchCandidateKeys ${describe(c)}: expected ${c['count']} '
          '${jsonEncode(head)}, got ${rows.length} (count $count) '
          '${jsonEncode(gotHead)}',
        );
      }
      // Every key once: (id, label, hexcode, protocol) is unique.
      final Set<String> seen = <String>{};
      for (final IrDbKeyCandidate r in rows) {
        if (!seen.add(
            '${r.id}\u0000${r.label}\u0000${r.hexcode}\u0000${r.protocol}')) {
          failures.add(
              'fetchCandidateKeys ${describe(c)}: ${r.label} listed twice');
          break;
        }
      }
    }
    expect(failures, isEmpty, reason: failures.take(8).join('\n'));
    expect(nonEmpty, greaterThan(400),
        reason: 'the sample must mostly hit rows');
  });

  test('paging a selection by limit and offset gives the same rows as one page',
      () async {
    int checked = 0;
    for (final Map<String, dynamic> c in casesFor('fetchCandidateKeys')) {
      if ((c['count'] as int) < 3) continue;
      if (checked++ % 7 != 0) continue;
      final Map<String, dynamic> a = c['args'] as Map<String, dynamic>;
      Future<List<IrDbKeyCandidate>> page(int limit, int offset) {
        return db.fetchCandidateKeys(
          brand: a['brand'] as String,
          model: a['model'] as String?,
          selectedProtocolId: a['protocol'] as String?,
          quickWinsFirst: a['quickWinsFirst'] as bool,
          hexPrefixUpper: a['hexPrefix'] as String?,
          search: a['search'] as String?,
          limit: limit,
          offset: offset,
        );
      }

      final List<IrDbKeyCandidate> whole = await page(_all, 0);
      final List<IrDbKeyCandidate> pieces = <IrDbKeyCandidate>[];
      for (int offset = 0; offset < whole.length + 5; offset += 7) {
        pieces.addAll(await page(7, offset));
      }
      expect(_digestRows(pieces), _digestRows(whole), reason: describe(c));
      expect(await page(1, whole.length - 1), hasLength(1));
      expect(await page(5, whole.length), isEmpty);
    }
    expect(checked, greaterThan(20));
  });
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
