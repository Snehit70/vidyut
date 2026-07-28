import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/update/github_update_checker.dart';

String _releaseJson({
  required String tag,
  String body = 'Release notes',
  List<Map<String, String>> assets = const [],
}) {
  final assetsJson = assets
      .map(
        (a) => '{"name":"${a['name']}","browser_download_url":"${a['url']}"}',
      )
      .join(',');
  return '{"tag_name":"$tag","body":"$body","assets":[$assetsJson]}';
}

void main() {
  test('accepts only versioned ARM64 release APK names', () {
    expect(isInstallableApkAsset('vidyut-1.2.1-arm64.apk'), isTrue);
    expect(isInstallableApkAsset('VIDYUT-1.2.1-ARM64.APK'), isTrue);
    expect(isInstallableApkAsset('vidyut-1.2.1-x86_64.apk'), isFalse);
    expect(isInstallableApkAsset('vidyut-debug.apk'), isFalse);
    expect(isInstallableApkAsset('other-1.2.1-arm64.apk'), isFalse);
  });

  group('SemVer', () {
    test('parses with and without a leading v', () {
      expect(SemVer.tryParse('1.2.3').toString(), '1.2.3');
      expect(SemVer.tryParse('v1.2.3').toString(), '1.2.3');
    });

    test('returns null for unparseable input', () {
      expect(SemVer.tryParse('not-a-version'), isNull);
      expect(SemVer.tryParse(''), isNull);
    });

    test('compares major, then minor, then patch', () {
      expect(
        SemVer.tryParse('2.0.0')!.compareTo(SemVer.tryParse('1.9.9')!),
        greaterThan(0),
      );
      expect(
        SemVer.tryParse('1.3.0')!.compareTo(SemVer.tryParse('1.2.9')!),
        greaterThan(0),
      );
      expect(
        SemVer.tryParse('1.2.4')!.compareTo(SemVer.tryParse('1.2.3')!),
        greaterThan(0),
      );
      expect(SemVer.tryParse('1.2.3')!.compareTo(SemVer.tryParse('1.2.3')!), 0);
    });
  });

  group('resolveUpdate', () {
    test('reports up to date when latest tag equals current version', () {
      final result = resolveUpdate(
        currentVersion: '1.2.0',
        statusCode: 200,
        responseBody: _releaseJson(tag: 'v1.2.0'),
        assetNameMatches: isInstallableApkAsset,
      );
      expect(result, isA<UpToDate>());
    });

    test(
      'reports up to date when latest tag is older than current version',
      () {
        final result = resolveUpdate(
          currentVersion: '1.3.0',
          statusCode: 200,
          responseBody: _releaseJson(tag: 'v1.2.0'),
          assetNameMatches: isInstallableApkAsset,
        );
        expect(result, isA<UpToDate>());
      },
    );

    test(
      'reports an update with the matching asset when a newer tag exists',
      () {
        final result = resolveUpdate(
          currentVersion: '1.0.0',
          statusCode: 200,
          responseBody: _releaseJson(
            tag: 'v1.1.0',
            assets: [
              {
                'name': 'vidyut-relay-1.1.0-linux-x64',
                'url': 'https://example.com/relay',
              },
              {
                'name': 'unrelated.apk.sha256',
                'url': 'https://example.com/unrelated.sha256',
              },
              {
                'name': 'vidyut-1.1.0-arm64.apk',
                'url': 'https://example.com/app.apk',
              },
              {
                'name': 'vidyut-1.1.0-arm64.apk.sha256',
                'url': 'https://example.com/app.sha256',
              },
            ],
          ),
          assetNameMatches: isInstallableApkAsset,
        );
        expect(result, isA<UpdateAvailable>());
        final update = result as UpdateAvailable;
        expect(update.version.toString(), '1.1.0');
        expect(update.tagName, 'v1.1.0');
        expect(update.assetName, 'vidyut-1.1.0-arm64.apk');
        expect(update.downloadUrl, 'https://example.com/app.apk');
        expect(update.sha256Url, 'https://example.com/app.sha256');
      },
    );

    test(
      'reports missing asset when a newer tag exists without a matching asset',
      () {
        final result = resolveUpdate(
          currentVersion: '1.0.0',
          statusCode: 200,
          responseBody: _releaseJson(
            tag: 'v1.1.0',
            assets: [
              {
                'name': 'vidyut-relay-1.1.0-linux-x64',
                'url': 'https://example.com/relay',
              },
            ],
          ),
          assetNameMatches: isInstallableApkAsset,
        );
        expect(result, isA<MissingAsset>());
        expect((result as MissingAsset).tagName, 'v1.1.0');
      },
    );

    test('reports no release found on 404', () {
      final result = resolveUpdate(
        currentVersion: '1.0.0',
        statusCode: 404,
        responseBody: '',
        assetNameMatches: isInstallableApkAsset,
      );
      expect(result, isA<NoReleaseFound>());
    });

    test('reports rate limited on 403 and 429', () {
      for (final status in [403, 429]) {
        final result = resolveUpdate(
          currentVersion: '1.0.0',
          statusCode: status,
          responseBody: '',
          assetNameMatches: isInstallableApkAsset,
        );
        expect(result, isA<RateLimited>());
      }
    });

    test('reports malformed metadata on invalid JSON', () {
      final result = resolveUpdate(
        currentVersion: '1.0.0',
        statusCode: 200,
        responseBody: 'not json',
        assetNameMatches: isInstallableApkAsset,
      );
      expect(result, isA<MalformedMetadata>());
    });

    test('reports malformed metadata when tag_name is missing', () {
      final result = resolveUpdate(
        currentVersion: '1.0.0',
        statusCode: 200,
        responseBody: '{"body":"notes","assets":[]}',
        assetNameMatches: isInstallableApkAsset,
      );
      expect(result, isA<MalformedMetadata>());
    });

    test('reports malformed metadata when tag_name is not valid semver', () {
      final result = resolveUpdate(
        currentVersion: '1.0.0',
        statusCode: 200,
        responseBody: _releaseJson(tag: 'not-a-version'),
        assetNameMatches: isInstallableApkAsset,
      );
      expect(result, isA<MalformedMetadata>());
    });
  });
}
