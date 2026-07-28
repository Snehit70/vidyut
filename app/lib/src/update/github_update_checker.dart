import 'dart:convert';
import 'dart:io';

/// A parsed `major.minor.patch` version, with an optional leading `v` stripped.
class SemVer implements Comparable<SemVer> {
  const SemVer(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static SemVer? tryParse(String raw) {
    final cleaned = raw.trim().startsWith('v')
        ? raw.trim().substring(1)
        : raw.trim();
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(cleaned);
    if (match == null) return null;
    return SemVer(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  @override
  int compareTo(SemVer other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  String toString() => '$major.$minor.$patch';
}

/// Outcome of comparing the running app version against the latest GitHub release.
sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

class UpToDate extends UpdateCheckResult {
  const UpToDate();
}

class UpdateAvailable extends UpdateCheckResult {
  const UpdateAvailable({
    required this.version,
    required this.tagName,
    required this.releaseNotes,
    required this.downloadUrl,
    required this.assetName,
    required this.sha256Url,
  });

  final SemVer version;
  final String tagName;
  final String releaseNotes;
  final String downloadUrl;
  final String assetName;
  final String sha256Url;
}

/// The release exists and parses, but none of its assets match [assetNameMatches].
class MissingAsset extends UpdateCheckResult {
  const MissingAsset(this.tagName);
  final String tagName;
}

/// The response body wasn't the JSON shape we expect, or the tag isn't a valid semver.
class MalformedMetadata extends UpdateCheckResult {
  const MalformedMetadata(this.detail);
  final String detail;
}

/// No release has been published yet (HTTP 404).
class NoReleaseFound extends UpdateCheckResult {
  const NoReleaseFound();
}

/// GitHub's API rate limit was hit (HTTP 403/429).
class RateLimited extends UpdateCheckResult {
  const RateLimited();
}

/// The request couldn't complete — no network, DNS failure, timeout, etc.
class UpdateCheckOffline extends UpdateCheckResult {
  const UpdateCheckOffline(this.detail);
  final String detail;
}

/// Decides what to tell the user given the current app version and a
/// `GET /repos/:owner/:repo/releases/latest` response body.
///
/// Kept separate from the HTTP call so it can be unit tested with fixture
/// JSON instead of a real network round-trip.
UpdateCheckResult resolveUpdate({
  required String currentVersion,
  required int statusCode,
  required String responseBody,
  required bool Function(String assetName) assetNameMatches,
}) {
  if (statusCode == 404) return const NoReleaseFound();
  if (statusCode == 403 || statusCode == 429) return const RateLimited();
  if (statusCode != 200) {
    return MalformedMetadata('unexpected status code $statusCode');
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(responseBody);
  } on FormatException catch (e) {
    return MalformedMetadata('invalid JSON: $e');
  }
  if (decoded is! Map<String, dynamic>) {
    return const MalformedMetadata('response body is not a JSON object');
  }

  final tagName = decoded['tag_name'];
  if (tagName is! String || tagName.isEmpty) {
    return const MalformedMetadata('missing tag_name');
  }

  final latest = SemVer.tryParse(tagName);
  if (latest == null) {
    return MalformedMetadata('tag_name "$tagName" is not a valid semver');
  }

  final current = SemVer.tryParse(currentVersion);
  if (current == null) {
    return MalformedMetadata(
      'current version "$currentVersion" is not a valid semver',
    );
  }

  if (latest.compareTo(current) <= 0) {
    return const UpToDate();
  }

  final assets = decoded['assets'];
  if (assets is! List) {
    return MissingAsset(tagName);
  }
  String? sha256Url;
  for (final asset in assets) {
    if (asset is! Map<String, dynamic>) continue;
    final name = asset['name'];
    final url = asset['browser_download_url'];
    if (name is String &&
        url is String &&
        name.toLowerCase().endsWith('.apk.sha256')) {
      sha256Url = url;
    }
  }
  for (final asset in assets) {
    if (asset is! Map<String, dynamic>) continue;
    final name = asset['name'];
    final url = asset['browser_download_url'];
    if (name is String && url is String && assetNameMatches(name)) {
      if (sha256Url == null) return MissingAsset(tagName);
      return UpdateAvailable(
        version: latest,
        tagName: tagName,
        releaseNotes: (decoded['body'] as String?) ?? '',
        downloadUrl: url,
        assetName: name,
        sha256Url: sha256Url,
      );
    }
  }
  return MissingAsset(tagName);
}

/// Checks GitHub Releases for a newer version of the app than [currentVersion].
class GithubUpdateChecker {
  GithubUpdateChecker({
    required this.owner,
    required this.repo,
    this.timeout = const Duration(seconds: 10),
  });

  final String owner;
  final String repo;
  final Duration timeout;

  bool _isDebugApk(String assetName) =>
      assetName.toLowerCase().endsWith('.apk') && assetName.contains('debug');

  Future<UpdateCheckResult> check(String currentVersion) async {
    final uri = Uri.https(
      'api.github.com',
      '/repos/$owner/$repo/releases/latest',
    );
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      request.headers.set(HttpHeaders.userAgentHeader, '$repo-update-checker');
      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      return resolveUpdate(
        currentVersion: currentVersion,
        statusCode: response.statusCode,
        responseBody: body,
        assetNameMatches: _isDebugApk,
      );
    } catch (e) {
      return UpdateCheckOffline(e.toString());
    } finally {
      client.close(force: true);
    }
  }
}
