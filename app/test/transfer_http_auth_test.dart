import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/shared/transfer_http_auth.dart';

void main() {
  test('matches the TypeScript transfer HTTP signature', () async {
    final auth = await createTransferHttpAuth(
      pairingSecret: 'pairing-secret',
      method: 'GET',
      pathAndQuery: '/transfer/v1/transfer_123/file_456?offset=4096',
      date: 1753689600000,
    );

    expect(auth.date, '1753689600000');
    expect(
      auth.authorization,
      'Vidyut pNMwIyTJrLVOpssRGSLZZb5npmfgIlryed929PzkfGo',
    );
  });
}
