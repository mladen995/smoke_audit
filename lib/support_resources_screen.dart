// lib/support_resources_screen.dart
//
// Static list of free quit-smoking help lines and sites. Tapping a phone number
// opens the dialer; tapping a site opens the browser. If the phone cannot open
// the link, the number/address is copied to the clipboard instead.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

class _Resource {
  const _Resource(this.title, this.detail, this.uri, this.icon);
  final String title;
  final String detail;
  final String uri;
  final IconData icon;
}

class _Region {
  const _Region(this.name, this.items);
  final String name;
  final List<_Resource> items;
}

const List<_Region> _regions = [
  _Region('United States', [
    _Resource('1-800-QUIT-NOW', '1-800-784-8669 · free coaching, connects to your state quitline',
        'tel:18007848669', Icons.phone_rounded),
    _Resource('Smokefree.gov', 'Plans, tips and text-message support',
        'https://smokefree.gov', Icons.language_rounded),
    _Resource('988 Suicide & Crisis Lifeline', 'Call or text 988 if you feel overwhelmed or unsafe',
        'tel:988', Icons.favorite_rounded),
  ]),
  _Region('United Kingdom', [
    _Resource('NHS Smokefree helpline', '0300 123 1044',
        'tel:03001231044', Icons.phone_rounded),
    _Resource('NHS Better Health: Quit smoking', 'Free support and quit aids',
        'https://www.nhs.uk/better-health/quit-smoking/', Icons.language_rounded),
  ]),
  _Region('Canada', [
    _Resource('Smokers’ Helpline', '1-866-366-3667',
        'tel:18663663667', Icons.phone_rounded),
  ]),
  _Region('Australia', [
    _Resource('Quitline', '13 7848',
        'tel:137848', Icons.phone_rounded),
    _Resource('Quit.org.au', 'Information and support',
        'https://www.quit.org.au', Icons.language_rounded),
  ]),
  _Region('Anywhere', [
    _Resource('World Health Organization: Quit tobacco', 'General guidance',
        'https://www.who.int/campaigns/world-no-tobacco-day', Icons.language_rounded),
  ]),
];

class SupportResourcesScreen extends StatelessWidget {
  const SupportResourcesScreen({super.key});

  Future<void> _open(BuildContext context, _Resource r) async {
    final Uri uri = Uri.parse(r.uri);
    bool ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (ok || !context.mounted) return;
    final String text = r.uri.startsWith('tel:') ? r.uri.substring(4) : r.uri;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not open it. Copied "$text" instead.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Support & help')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Cravings pass, usually within a few minutes. If one is strong, '
            'calling a quitline is free and works better than going it alone.',
            style: TextStyle(fontSize: 15, height: 1.4),
          ),
          const SizedBox(height: 16),
          for (final _Region region in _regions) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 6),
              child: Text(region.name,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
            ),
            for (final _Resource r in region.items)
              Card(
                child: ListTile(
                  leading: Icon(r.icon, color: Colors.teal.shade700),
                  title: Text(r.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(r.detail),
                  onTap: () => _open(context, r),
                ),
              ),
          ],
          const SizedBox(height: 20),
          const Text(
            'AirEngine is not a medical device and does not replace advice from a doctor or pharmacist. '
            'In an emergency, call your local emergency number. '
            'Numbers can change, so check the official site if a call does not connect.',
            style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.4),
          ),
        ],
      ),
    );
  }
}
