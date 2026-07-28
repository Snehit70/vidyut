import 'dart:convert';

class PairingCode {
  const PairingCode({
    required this.host,
    required this.port,
    required this.secret,
    this.name,
  });

  final String host;
  final int port;
  final String secret;
  final String? name;

  @override
  bool operator ==(Object other) {
    return other is PairingCode &&
        other.host == host &&
        other.port == port &&
        other.secret == secret;
  }

  @override
  int get hashCode => Object.hash(host, port, secret);

  static PairingCode parse(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      throw const PairingCodeException('Pairing code must be a JSON object.');
    }
    if (decoded['v'] != 1 || decoded['service'] != 'vidyut') {
      throw const PairingCodeException('Pairing code is not for Vidyut.');
    }

    final host = decoded['host'];
    final port = decoded['port'];
    final secret = decoded['secret'];
    final name = decoded['name'];
    if (host is! String || host.isEmpty) {
      throw const PairingCodeException('Pairing code is missing a host.');
    }
    if (port is! int || port <= 0 || port > 65535) {
      throw const PairingCodeException('Pairing code has an invalid port.');
    }
    if (secret is! String || secret.isEmpty) {
      throw const PairingCodeException('Pairing code is missing a secret.');
    }

    return PairingCode(
      host: host,
      port: port,
      secret: secret,
      name: name is String && name.trim().isNotEmpty ? name.trim() : null,
    );
  }

  static PairingCode parseManual({
    required String host,
    required String port,
    required String secret,
  }) {
    final parsedPort = int.tryParse(port.trim());
    if (host.trim().isEmpty) {
      throw const PairingCodeException('Host is required.');
    }
    if (parsedPort == null || parsedPort <= 0 || parsedPort > 65535) {
      throw const PairingCodeException('Port must be between 1 and 65535.');
    }
    if (secret.trim().isEmpty) {
      throw const PairingCodeException('Pairing secret is required.');
    }
    return PairingCode(
      host: host.trim(),
      port: parsedPort,
      secret: secret.trim(),
    );
  }
}

class PairingCodeException implements Exception {
  const PairingCodeException(this.message);

  final String message;

  @override
  String toString() => message;
}
