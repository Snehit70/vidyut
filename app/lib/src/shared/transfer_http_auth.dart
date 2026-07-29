import 'dart:convert';

import 'package:cryptography/cryptography.dart';

class TransferHttpAuth {
  const TransferHttpAuth({required this.date, required this.authorization});

  final String date;
  final String authorization;

  Map<String, String> get headers => {
    'x-vidyut-date': date,
    'authorization': authorization,
  };
}

Future<TransferHttpAuth> createTransferHttpAuth({
  required String pairingSecret,
  required String method,
  required String pathAndQuery,
  int? date,
}) async {
  final dateValue = (date ?? DateTime.now().millisecondsSinceEpoch).toString();
  final canonical = '${method.toUpperCase()}\n$pathAndQuery\n$dateValue';
  final mac = await Hmac.sha256().calculateMac(
    utf8.encode(canonical),
    secretKey: SecretKey(utf8.encode(pairingSecret)),
  );
  return TransferHttpAuth(
    date: dateValue,
    authorization: 'Vidyut ${base64UrlEncode(mac.bytes).replaceAll('=', '')}',
  );
}
