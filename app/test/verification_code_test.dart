import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/push/verification_code.dart';
import 'package:vidyut_clipboard/vidyut_clipboard.dart';

void main() {
  group('extractVerificationCode', () {
    const cases = {
      'Your OTP is 482913. Do not share it with anyone.': '482913',
      '482913 is your verification code': '482913',
      'G-772031 is your Google verification code.': '772031',
      'Your login code: 123 456': '123456',
      'Use 908-112 to sign in': '908112',
      'Your PIN is 4821': '4821',
      'Code 55821904 expires in 10 minutes': '55821904',
      // The number nearest the keyword wins over a reference number.
      'Ref 99887766. Your OTP for the transfer is 3141.': '3141',
      // An amount next to the code is not the code.
      'OTP 602214 for Rs. 4500 at Amazon': '602214',
      'Rs.4500 debited. OTP 602214': '602214',
      'Android sign-in code 7712': '7712',
    };
    for (final MapEntry(key: text, value: code) in cases.entries) {
      test('finds $code in "$text"', () {
        expect(extractVerificationCode(text), code);
      });
    }

    const misses = [
      'Meeting moved to 1430 tomorrow',
      'Your order 482913 has shipped',
      'Call me on 98765 43210 about the code',
      'Login from a new device at 10:45',
      'Your code review got 2 comments',
      'Rs. 4500 paid with PIN',
      'Ref 99887766 for your code change',
      'A/c XX1234 debited. Not you? Reset your PIN',
    ];
    for (final text in misses) {
      test('finds nothing in "$text"', () {
        expect(extractVerificationCode(text), isNull);
      });
    }
  });

  group('VerificationCodeFilter', () {
    PostedNotification posted(String text, {String app = 'com.bank'}) =>
        PostedNotification(packageName: app, title: 'Bank', text: text);

    test('sends a code once per window, even from two apps', () {
      var now = DateTime(2026, 10, 23, 12);
      final filter = VerificationCodeFilter(now: () => now);

      expect(filter.codeFor(posted('Your OTP is 482913')), '482913');
      expect(
        filter.codeFor(posted('Your OTP is 482913', app: 'com.sms')),
        isNull,
      );
      now = now.add(const Duration(minutes: 2));
      expect(filter.codeFor(posted('Your OTP is 482913')), '482913');
    });

    test('reads the title too', () {
      final filter = VerificationCodeFilter();

      expect(
        filter.codeFor(
          const PostedNotification(
            packageName: 'com.app',
            title: 'Verification code',
            text: '738201',
          ),
        ),
        '738201',
      );
    });

    test('ignores a notification with no code', () {
      expect(
        VerificationCodeFilter().codeFor(posted('Your balance is 1200')),
        isNull,
      );
    });
  });
}
