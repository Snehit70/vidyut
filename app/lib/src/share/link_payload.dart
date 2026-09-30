/// Decides whether copied text is a single URL worth opening in a browser.
///
/// Deliberately offline. Probing the URL to be certain would add latency to
/// every copy and hand the address to a third party, and the payoff is small:
/// if the format reads as a URL, opening it either works or the browser shows
/// its own error page. Format is enough.
///
/// The rule is lenient by intent, because the cost of a false positive is a
/// browser tab and the cost of a false negative is the feature not firing on
/// the thing it exists for. So `hello.world` counts, while anything with
/// whitespace in it, a bare version number, or ordinary prose does not.
bool looksLikeUrl(String raw) {
  final text = raw.trim();
  // Long past any real address. A pasted document should not be launched.
  if (text.isEmpty || text.length > 2048) return false;
  // A URL cannot contain an unencoded space, so its presence means this is a
  // sentence, a line, or a selection. This is what keeps prose out.
  if (text.contains(RegExp(r'\s'))) return false;
  // Control characters would mean the clipboard held something other than
  // text, and would be passed straight to a process argument.
  if (text.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) return false;

  // Explicit scheme. http and https only, so file:// and javascript: are never
  // handed to a browser from a clipboard.
  final schemeMatch = RegExp(
    r'^(https?)://',
    caseSensitive: false,
  ).firstMatch(text);
  if (schemeMatch != null) {
    return _hasHost(text.substring(schemeMatch.end));
  }

  // localhost, with or without a port and path. Common enough when working on
  // something, and it is a real address the browser can open.
  if (RegExp(
    r'^localhost(:\d{1,5})?(/\S*)?$',
    caseSensitive: false,
  ).hasMatch(text)) {
    return true;
  }

  // A bare or explicitly written host, optionally with a port and path.
  return _hasHost(text);
}

/// True when [rest] starts with something host-shaped, with an optional port and
/// path. [rest] is whatever followed the scheme, or the whole string when there
/// was no scheme.
bool _hasHost(String rest) {
  final authority = rest.split(RegExp(r'[/?#]')).first;
  if (authority.isEmpty) return false;

  // A bracketed IPv6 literal owns its colons, so the port is whatever follows
  // the closing bracket.
  if (authority.startsWith('[')) {
    final close = authority.indexOf(']');
    if (close < 0) return false;
    return RegExp(r'^\[[0-9A-Fa-f:.]+\]$')
        .hasMatch(authority.substring(0, close + 1));
  }

  var host = authority;
  final port = RegExp(r':\d{1,5}$').firstMatch(host);
  if (port != null) host = host.substring(0, port.start);
  if (host.isEmpty) return false;

  // localhost is the one undotted host worth accepting. Any other single label
  // is indistinguishable from an ordinary word, so it is left out.
  if (host.toLowerCase() == 'localhost') return true;
  if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) return true;
  return _hasDottedName(host);
}

/// A dotted name whose last label is alphabetic. Requiring the final label to
/// be letters is what rejects a bare `3.14` or a version string while still
/// accepting `example.com` and `a.b.co.uk`.
bool _hasDottedName(String host) {
  final labels = host.split('.');
  if (labels.length < 2) return false;
  if (labels.any((label) => label.isEmpty)) return false;
  if (labels.any((label) => !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(label))) {
    return false;
  }
  final tld = labels.last;
  return RegExp(r'^[A-Za-z]{2,24}$').hasMatch(tld);
}
