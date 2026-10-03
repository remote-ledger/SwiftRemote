import 'package:swiftremote/ir_finder/ir_finder_models.dart';
import 'package:swiftremote/ledger_db/ledger_errors.dart';
import 'package:swiftremote/utils/ledger_signal.dart';
import 'package:swiftremote/utils/remote.dart';
import 'package:uuid/uuid.dart';

/// A database protocol name as the app's protocol ids spell it (`RCA-38` is
/// `rca_38`).
String normalizedDbProtocolId(String dbProtocol) =>
    dbProtocol.trim().toLowerCase().replaceAll('-', '_');

/// The Signal Tester candidate a database row stands for.
///
/// A protocol the ledger's compiled signal stands in for
/// ([IrDbKeyCandidate.requiresSignal]) becomes a candidate that plays that
/// signal. It is never built from the row's hex code: the app's decoders read
/// those protocols' database codes differently from the wire, so a code sent
/// that way would not be the one the database lists. Without its signal such a
/// row has no candidate, and this throws [LedgerSignalUnavailable].
///
/// Every other row is decoded as it always was: [displayName] names the
/// protocol, [buildParams] reads the hex code into the protocol's fields and
/// [fitHex] writes it for display. Those three are the screen's own and are
/// not called for a row that plays a signal.
IrFinderCandidate candidateForDbRow(
  IrDbKeyCandidate row, {
  required String? brand,
  required String? model,
  required String Function(String protocolId) displayName,
  required Map<String, dynamic> Function(String protocolId, String hexcode)
      buildParams,
  required String Function(String protocolId, String hexcode) fitHex,
}) {
  final String protocolId = normalizedDbProtocolId(row.protocol);

  if (row.requiresSignal) {
    final LedgerPlayback? press = row.signal?.playback();
    if (press == null) throw LedgerSignalUnavailable(row.protocol);
    String name;
    try {
      name = displayName(protocolId);
    } catch (_) {
      name = row.protocol;
    }
    return IrFinderCandidate(
      protocolId: protocolId,
      displayProtocol: name,
      displayCode: fitHex(protocolId, row.hexcode),
      params: const <String, dynamic>{},
      source: IrFinderSource.database,
      dbRemoteId: row.remoteId,
      dbLabel: row.label,
      dbBrand: brand,
      dbModel: model,
      raw: press,
    );
  }

  final String name = displayName(protocolId);
  final Map<String, dynamic> params = buildParams(protocolId, row.hexcode);
  return IrFinderCandidate(
    protocolId: protocolId,
    displayProtocol: name,
    displayCode: fitHex(protocolId, row.hexcode),
    params: params,
    source: IrFinderSource.database,
    dbRemoteId: row.remoteId,
    dbLabel: row.label,
    dbBrand: brand,
    dbModel: model,
  );
}

/// The button a saved Signal Tester hit becomes.
///
/// A hit found as a signal becomes a raw button of that press. Any other hit
/// is rebuilt from the parameters it was tested with, which is what a hit
/// saved before the database was read from the ledger holds: the user tested
/// those, so they are kept as they are.
IRButton buttonForHit(IrFinderHit hit, {String? kaseikyoVendor}) {
  const Uuid uuid = Uuid();
  if (hit.rawData != null) {
    final LedgerPlayback? press = hit.rawPlayback;
    if (press == null) {
      throw StateError('The saved signal of this hit cannot be played.');
    }
    return IRButton(
      id: uuid.v4(),
      code: null,
      rawData: press.rawData,
      frequency: press.frequencyHz,
      image: hit.dbLabel ?? hit.code,
      isImage: false,
      protocol: null,
      protocolParams: null,
    );
  }
  final Map<String, dynamic> params = IrFinderParams.paramsForHit(
    hit,
    kaseikyoVendor: kaseikyoVendor,
  );
  return IRButton(
    id: uuid.v4(),
    code: null,
    rawData: null,
    frequency: null,
    image: hit.dbLabel ?? hit.code,
    isImage: false,
    protocol: hit.protocolId,
    protocolParams: params,
  );
}
