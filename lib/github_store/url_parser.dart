import 'models.dart';

/// The segment GitHub places after `owner/repo` when a link points inside the
/// repository: `tree` for a folder in the web UI, `blob` for a file, and `raw`
/// for that same file's bytes. All three are followed by the branch and then
/// the path, so one branch of the parser can unwrap the lot.
const Set<String> _refKindSegments = <String>{'tree', 'blob', 'raw'};

RepoRef? parseGitHubUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  if (uri.host.toLowerCase() != 'github.com') return null;

  // pathSegments resolves percent-escapes, so a link to a folder whose name
  // contains a space reaches us as "Audio Receivers" rather than
  // "Audio%20Receivers". The store service builds its API request with
  // Uri.https, which escapes the path again, and a path that arrived already
  // escaped would be sent double-escaped and match no folder at all.
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.length < 2) return null;

  final owner = segs[0];
  final repo = segs[1];
  var branch = '';
  var path = '';

  if (segs.length >= 4 && _refKindSegments.contains(segs[2])) {
    branch = segs[3];
    final rest = segs.sublist(4);
    if (segs[2] == 'tree') {
      path = rest.join('/');
    } else if (rest.isNotEmpty) {
      // A blob or raw link names a file, but RepoRef.path is handed to the
      // contents API as a folder to list, so keeping the file name would ask
      // GitHub for a directory listing of a file and fail. Somebody who
      // pastes a link to an .ir file wants to reach that file, so drop the
      // last segment and open the folder holding it; previously the branch
      // and the folder were both discarded and the browser silently jumped
      // to the repository root.
      path = rest.sublist(0, rest.length - 1).join('/');
    }
  }

  return RepoRef(
    owner: owner,
    repo: repo,
    branch: branch,
    path: path,
    originalUrl: url,
  );
}
