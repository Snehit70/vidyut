import 'package:flutter/material.dart';

/// Turns GitHub's generated release notes into plain display lines.
///
/// The release workflow publishes with `generate_release_notes: true`, so a body
/// is a `## What's Changed` heading, then one `* type: summary by @user in url`
/// line per commit, then a bold full-changelog link. None of that needs a
/// markdown dependency once the decoration is stripped, and the stripped form
/// is what reads well on a narrow screen anyway.
List<String> readReleaseNotes(String raw) {
  final lines = <String>[];
  for (final rawLine in raw.split('\n')) {
    var text = rawLine.trim();
    if (text.isEmpty) continue;
    // Section headings such as "## What's Changed".
    if (text.startsWith('#')) continue;
    // The trailing "**Full Changelog**: url" line.
    if (text.toLowerCase().contains('full changelog')) continue;
    if (text.startsWith('*') || text.startsWith('-') || text.startsWith('•')) {
      text = text.substring(1).trim();
    }
    if (text.isEmpty) continue;
    // Each generated line ends with "in <pull-url>". The link is noise on a
    // phone. Requiring a "by @" before the match keeps this from eating an
    // "in http..." that a hand-written summary legitimately contains.
    final urlStart = text.lastIndexOf(' in http');
    if (urlStart > 0 && text.substring(0, urlStart).contains(' by @')) {
      text = text.substring(0, urlStart);
    }
    lines.add(text);
  }
  return lines;
}

/// Reads what changed in a release without leaving the app.
class WhatsNewScreen extends StatelessWidget {
  const WhatsNewScreen({
    super.key,
    required this.version,
    required this.releaseNotes,
  });

  /// The release these notes describe, or null when the response named none.
  final String? version;

  final String releaseNotes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = readReleaseNotes(releaseNotes);
    return Scaffold(
      appBar: AppBar(title: const Text("What's new")),
      body: entries.isEmpty
          ? _empty(context)
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              itemCount: entries.length + 1,
              separatorBuilder: (_, _) => const SizedBox(height: 14),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      version == null ? 'Latest release' : 'Vidyut $version',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 7, right: 10),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: const SizedBox(width: 5, height: 5),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        entries[index - 1],
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.article_outlined,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 14),
            Text(
              'No release notes yet',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              version == null
                  ? 'GitHub has not published notes for a release yet.'
                  : 'Vidyut $version shipped without release notes.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
