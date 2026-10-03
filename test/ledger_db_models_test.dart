import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftremote/ledger_db/ledger_errors.dart';
import 'package:swiftremote/ledger_db/ledger_models.dart';

import 'support/ledger_fixtures.dart';

Uint8List _json(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

void main() {
  group('manifest', () {
    test('reads the real manifest: version, protocols and where files are', () {
      final LedgerManifest m =
          LedgerManifest.parse(fixtureBytes('manifest.json'));

      expect(m.schemaVersion, 1);
      expect(m.dataVersion, hasLength(12));
      expect(m.protocols, hasLength(23));
      expect(m.counts['brands'], 4902);
      expect(m.brandsPath, 'brands.json');
      expect(m.brandModelsPath('6f4800a854'), 'b/6f4800a854.m.json');
      expect(m.brandKeysPath('6f4800a854'), 'b/6f4800a854.k.json');
      expect(m.signalsPath('SONY12'), 's/SONY12.json');
      expect(m.powerPath, 'power.json');
    });

    test('says from data which protocols the app plays from a signal', () {
      final LedgerManifest m =
          LedgerManifest.parse(fixtureBytes('manifest.json'));

      final Set<String> signal = <String>{
        for (final LedgerProtocol p in m.protocols)
          if (p.appReadingDiffers) p.db,
      };
      expect(signal, <String>{
        'SONY12', 'SONY15', 'SONY20', 'Pioneer', 'JVC', 'Sharp', 'Denon',
        'Thomson7', 'Proton', 'RCC2026', //
      });
      for (final LedgerProtocol p in m.protocols) {
        expect(p.play != null, p.appReadingDiffers, reason: p.db);
        expect(p.index, m.protocols.indexOf(p));
      }
    });

    test('carries how one press is played, and a protocol with no carrier', () {
      final LedgerManifest m =
          LedgerManifest.parse(fixtureBytes('manifest.json'));

      final LedgerPlay sharp = m.protocolByDb('Sharp')!.play!;
      expect(sharp.repeatPasses, 1);
      expect(sharp.helperRepeatPasses, 0);
      expect(sharp.rule, 'full-signal');
      expect(m.protocolByDb('SONY12')!.play!.repeatPasses, 3);
      expect(m.protocolByDb('SONY12')!.play!.introEmpty, isTrue);
      expect(m.protocolByDb('Pioneer')!.play!.repeatPasses, 0);
      // The ledger's protocols for REC80 disagree on a carrier.
      expect(m.protocolByDb('REC80')!.carrierHz, isNull);
      expect(m.protocolByDb('REC80')!.carrierHzByLedger, isNotEmpty);
    });

    test('finds a protocol by the app\'s own spelling of its name', () {
      final LedgerManifest m =
          LedgerManifest.parse(fixtureBytes('manifest.json'));

      expect(m.protocolByKey('rca38')!.db, 'RCA_38');
      expect(m.protocolByKey('recs80l')!.db, 'RECS80_L');
      expect(m.protocolByKey('nec')!.db, 'NEC');
      expect(m.protocolByKey('kaseikyo'), isNull);
    });

    test('refuses a schema version it does not know', () {
      final dynamic good = fixtureJson('manifest.json');
      for (final Object? version in <Object?>[2, 0, 1.5, '1', null]) {
        final Map<String, dynamic> m = Map<String, dynamic>.from(good as Map);
        m['schemaVersion'] = version;
        expect(
          () => LedgerManifest.parse(_json(m)),
          throwsA(isA<LedgerDbUnavailable>().having(
            (LedgerDbUnavailable e) => e.reason,
            'reason',
            LedgerDbFailure.unsupportedVersion,
          )),
          reason: '$version',
        );
      }
    });

    test('refuses a manifest that is not one', () {
      expect(() => LedgerManifest.parse(_json(<Object?>[])),
          throwsFormatException);
      expect(
        () =>
            LedgerManifest.parse(_json(<String, Object?>{'schemaVersion': 1})),
        throwsFormatException,
      );
      expect(
        () => LedgerManifest.parse(Uint8List.fromList(utf8.encode('{nope'))),
        throwsFormatException,
      );
    });
  });

  group('brands', () {
    test('reads the 4,902 brands in NOCASE order with their keys and masks',
        () {
      final List<LedgerBrand> brands = parseBrands(fixtureBytes('brands.json'));

      expect(brands, hasLength(4902));
      expect(brands.first.name, '1 BY ONE');
      expect(brands.first.key, hasLength(10));
      final LedgerBrand sony =
          brands.firstWhere((LedgerBrand b) => b.name == 'SONY');
      expect(sony.protoMask, greaterThan(0));
      // Mixed-case names sort among the upper-case ones.
      final List<String> names = brands.map((LedgerBrand b) => b.name).toList();
      expect(names.indexOf('Citilux'), greaterThan(names.indexOf('CHINA')));
      expect(names.indexOf('Citilux'), lessThan(names.indexOf('CITIZEN')));
    });

    test('a brand\'s key is the first ten hex digits of the SHA-1 of its name',
        () {
      for (final LedgerBrand b
          in parseBrands(fixtureBytes('brands.json')).take(300)) {
        expect(sha1.convert(utf8.encode(b.name)).toString().substring(0, 10),
            b.key,
            reason: b.name);
      }
    });

    test('refuses a malformed brand list', () {
      expect(
          () => parseBrands(_json(<String, Object?>{})), throwsFormatException);
      expect(
          () => parseBrands(_json(<Object?>[
                <Object?>['A', 'k']
              ])),
          throwsFormatException);
    });
  });

  group('a brand\'s files', () {
    test('each key file hashes to the hash its models file gives', () {
      final List<LedgerBrand> brands = parseBrands(fixtureBytes('brands.json'));
      int checked = 0;
      for (final LedgerBrand b in brands) {
        try {
          fixtureBytes('b/${b.key}.k.json');
        } catch (_) {
          continue; // not a fixture brand
        }
        final LedgerBrandModels models =
            LedgerBrandModels.parse(fixtureBytes('b/${b.key}.m.json'));
        expect(models.brand, b.name);
        expect(sha256.convert(fixtureBytes('b/${b.key}.k.json')).toString(),
            startsWith(models.hash),
            reason: b.name);
        checked++;
      }
      expect(checked, greaterThan(20));
    });

    test('models and keys agree: ids, key counts, protocol masks', () {
      final LedgerBrand brand = parseBrands(fixtureBytes('brands.json'))
          .firstWhere((LedgerBrand b) => b.name == 'BRENNAN');
      final LedgerBrandModels models =
          LedgerBrandModels.parse(fixtureBytes('b/${brand.key}.m.json'));
      final LedgerBrandKeys keys =
          LedgerBrandKeys.parse(fixtureBytes('b/${brand.key}.k.json'));

      expect(keys.brand, 'BRENNAN');
      expect(keys.ids.toList()..sort(), models.ids.toList()..sort());
      int total = 0;
      for (int i = 0; i < models.ids.length; i++) {
        final int block = keys.blockOf(models.ids[i]);
        expect(block, greaterThanOrEqualTo(0));
        final int rows = keys.blockStart[block + 1] - keys.blockStart[block];
        expect(rows, models.idKeyCounts[i]);
        int mask = 0;
        for (int r = keys.blockStart[block];
            r < keys.blockStart[block + 1];
            r++) {
          mask |= 1 << keys.protocols[r];
        }
        expect(mask, models.idMasks[i]);
        total += rows;
      }
      expect(keys.rowCount, total);
      expect(brand.protoMask,
          models.maskOf(Iterable<int>.generate(models.ids.length)));
    });

    test('finds the block of a row, the model of an id, a model by name', () {
      final LedgerBrand brand = parseBrands(fixtureBytes('brands.json'))
          .firstWhere((LedgerBrand b) => b.name == 'B2B.TEST');
      final LedgerBrandModels models =
          LedgerBrandModels.parse(fixtureBytes('b/${brand.key}.m.json'));
      final LedgerBrandKeys keys =
          LedgerBrandKeys.parse(fixtureBytes('b/${brand.key}.k.json'));

      for (int b = 0; b < keys.ids.length; b++) {
        for (int r = keys.blockStart[b]; r < keys.blockStart[b + 1]; r++) {
          expect(keys.blockOfRow(r), b);
        }
      }
      expect(keys.blockOf(-5), -1);
      final LedgerModel first = models.models.first;
      expect(models.model(first.name), same(first));
      expect(models.model('no such model'), isNull);
      expect(
          models.firstModelOfId(models.ids[first.idIndexes.first]), first.name);
      expect(models.firstModelOfId(-1), isNull);
    });

    test('refuses malformed brand files', () {
      expect(
          () => LedgerBrandModels.parse(_json(<String, Object?>{'brand': 'X'})),
          throwsFormatException);
      expect(
          () => LedgerBrandKeys.parse(
              _json(<String, Object?>{'brand': 'X', 'r': 5})),
          throwsFormatException);
      expect(
        () => LedgerBrandKeys.parse(_json(<String, Object?>{
          'brand': 'X',
          'r': <Object?>[
            <Object?>[
              1,
              <Object?>[
                <Object?>['L', 'not an index', 'AA']
              ]
            ],
          ],
        })),
        throwsFormatException,
      );
    });
  });

  group('signal shards and the power list', () {
    test('a shard holds one Pronto string per code, and how to play them', () {
      final LedgerSignalShard shard =
          LedgerSignalShard.parse(fixtureBytes('s/Sharp.json'));

      expect(shard.protocol, 'Sharp');
      expect(shard.carrierHz, 38000);
      expect(shard.play!.repeatPasses, 1);
      expect(shard.signals, isNotEmpty);
      for (final String pronto in shard.signals.values) {
        expect(pronto, startsWith('0000 '));
      }
    });

    test('the power list carries protocol, hex, label, popularity and rank',
        () {
      final List<LedgerPowerRow> rows = parsePower(fixtureBytes('power.json'));

      expect(rows.first.label, 'POWER');
      expect(rows.first.nIds, greaterThan(100));
      expect(
          rows.every((LedgerPowerRow r) => r.rank == 0 || r.rank == 1), isTrue);
      // Most used first.
      for (int i = 1; i < rows.length; i++) {
        if (i < 60) expect(rows[i].nIds, lessThanOrEqualTo(rows[i - 1].nIds));
      }
    });

    test('refuses malformed shards and power lists', () {
      expect(() => LedgerSignalShard.parse(_json(<String, Object?>{'p': 'X'})),
          throwsFormatException);
      expect(
          () => parsePower(_json(<Object?>[
                <Object?>[1, 'AA', 'POWER', 3]
              ])),
          throwsFormatException);
    });
  });

  group('LedgerSignal', () {
    test('plays by the stated repeat passes, with the stated carrier', () {
      final LedgerSignalShard shard =
          LedgerSignalShard.parse(fixtureBytes('s/SONY12.json'));
      final String hex = shard.signals.keys.first;
      final LedgerSignal signal = LedgerSignal(
        protocol: 'SONY12',
        hexcode: hex,
        pronto: shard.signals[hex]!,
        carrierHz: shard.carrierHz,
        minSends: shard.minSends,
        play: shard.play,
      );

      final press = signal.playback()!;
      expect(press.frequencyHz, 40000);
      // Sony has no intro; a press is the 13 burst pairs of the repeat, three times.
      expect(press.pattern, hasLength(3 * 26));
    });

    test('falls back to the minSends rule when the API states no play', () {
      final LedgerSignalShard shard =
          LedgerSignalShard.parse(fixtureBytes('s/SONY12.json'));
      final String hex = shard.signals.keys.first;
      final LedgerSignal signal = LedgerSignal(
        protocol: 'SONY12',
        hexcode: hex,
        pronto: shard.signals[hex]!,
        carrierHz: null,
        minSends: 3,
        play: null,
      );

      expect(signal.playback()!.pattern, hasLength(3 * 26));
    });
  });
}
