import 'package:vidyut_clipboard/vidyut_clipboard.dart';

/// Words that sit next to a one-time code in an English notification.
final _keyword = RegExp(
  r'\b(?:code|otp|one[- ]time|verification|verify|passcode|password|pin|2fa|'
  r'two[- ]factor|security|authenticat\w*|log ?in|sign[- ]?in)\b',
  caseSensitive: false,
);

/// A 4–8 digit run, or two groups of three ("123 456", "123-456"), that is not
/// part of a longer number, a decimal, a time, a date or a percentage.
final _candidate = RegExp(
  r'(?<![\w+]|\d[.,:/ -])(\d{3}[- ]\d{3}|\d{4,8})(?![\w]|[.,:/ -]\d|\s?%)',
);

/// Not a code: an amount ("Rs. 4500", "₹4500") or a labelled number
/// ("Ref 99887766", "order #4521", "A/c XX1234").
final _labelBefore = RegExp(
  r'(?:[₹$€£]|\b(?:rs|inr|usd|eur|ref(?:erence)?|order|txn|a/c|acct|account|'
  r'id|no))\.?\s*[:#]?\s*$',
  caseSensitive: false,
);

/// The one-time code in a notification's text, digits only, or null when the
/// text does not read like one. A code must sit in text that names it ("code",
/// "OTP", "verify"...); when several numbers do, the one nearest that word wins.
String? extractVerificationCode(String text) {
  final keywords = _keyword.allMatches(text).toList();
  if (keywords.isEmpty) return null;
  String? best;
  var bestDistance = 1 << 30;
  for (final match in _candidate.allMatches(text)) {
    final before = text.substring(
      match.start < 16 ? 0 : match.start - 16,
      match.start,
    );
    if (_labelBefore.hasMatch(before)) continue;
    for (final keyword in keywords) {
      final distance = keyword.start >= match.end
          ? keyword.start - match.end
          : match.start >= keyword.end
          ? match.start - keyword.end
          : 0;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = match.group(1);
      }
    }
  }
  return best?.replaceAll(RegExp(r'[- ]'), '');
}

/// Picks the codes worth sending from posted notifications. The same code
/// often arrives twice (the SMS app and the bank's own app, or an update to
/// one notification), so a code is sent once per [window].
class VerificationCodeFilter {
  VerificationCodeFilter({
    this.window = const Duration(minutes: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration window;
  final DateTime Function() _now;
  final _sentAt = <String, DateTime>{};

  String? codeFor(PostedNotification notification) {
    final code = extractVerificationCode(
      '${notification.title}\n${notification.text}',
    );
    if (code == null) return null;
    final now = _now();
    _sentAt.removeWhere((_, at) => now.difference(at) >= window);
    if (_sentAt.containsKey(code)) return null;
    _sentAt[code] = now;
    return code;
  }
}
