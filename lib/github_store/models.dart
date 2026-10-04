import 'package:flutter/foundation.dart';

enum RepoItemType { file, dir }

@immutable
class RepoItem {
  final RepoItemType type;
  final String name;
  final String path;
  final int? size;
  final String? downloadUrl;
  final String? sha;

  const RepoItem({
    required this.type,
    required this.name,
    required this.path,
    this.size,
    this.downloadUrl,
    this.sha,
  });
}

@immutable
class GitHubFilePayload {
  final String name;
  final String path;
  final int size;
  final String text;

  const GitHubFilePayload({
    required this.name,
    required this.path,
    required this.size,
    required this.text,
  });
}
