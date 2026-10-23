/// The phone's "stop syncing my clipboard for a while" switch. While it is on,
/// a laptop copy is not written here, and screenshots and auto-read text are
/// not sent. A deliberate send (share sheet, "Send clipboard") still goes, and
/// file transfers are a separate path that keeps running.
class PhoneClipboardPause {
  const PhoneClipboardPause.off() : paused = false, until = null;

  const PhoneClipboardPause.untilResumed() : paused = true, until = null;

  const PhoneClipboardPause.until(DateTime this.until) : paused = true;

  final bool paused;

  /// When the pause lifts by itself; null while paused until resumed.
  final DateTime? until;

  bool activeAt(DateTime now) {
    if (!paused) return false;
    final until = this.until;
    return until == null || now.isBefore(until);
  }

  /// Storage and isolate-message form: empty when off, `resume` when paused
  /// until resumed, otherwise the deadline in epoch milliseconds.
  String encode() {
    if (!paused) return '';
    final until = this.until;
    return until == null ? 'resume' : '${until.millisecondsSinceEpoch}';
  }

  static PhoneClipboardPause decode(String? value) {
    if (value == 'resume') return const PhoneClipboardPause.untilResumed();
    final ms = int.tryParse(value ?? '');
    if (ms == null) return const PhoneClipboardPause.off();
    return PhoneClipboardPause.until(DateTime.fromMillisecondsSinceEpoch(ms));
  }

  @override
  bool operator ==(Object other) =>
      other is PhoneClipboardPause &&
      other.paused == paused &&
      other.until == until;

  @override
  int get hashCode => Object.hash(paused, until);
}
