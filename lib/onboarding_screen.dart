// lib/onboarding_screen.dart
import 'package:flutter/material.dart';

import 'models/user_profile.dart';
import 'utils/formatters.dart';

/// First-run setup AND "Edit profile" (when [initialProfile] is provided).
class OnboardingScreen extends StatefulWidget {
  final UserProfile? initialProfile;
  final String profileId;
  final DateTime? suggestedQuitDate;
  final void Function(UserProfile profile) onComplete;

  const OnboardingScreen({
    super.key,
    this.initialProfile,
    this.profileId = 'default',
    this.suggestedQuitDate,
    required this.onComplete,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const int _lastPage = 4;

  final PageController _controller = PageController();
  int _page = 0;

  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _cigsCtrl = TextEditingController();
  final TextEditingController _yearsCtrl = TextEditingController();
  final TextEditingController _priceCtrl = TextEditingController();

  DateTime? _dob;
  BiologicalSex _sex = BiologicalSex.unspecified;
  double _heightCm = 170;
  bool _useImperial = true;
  SmokingStatus _status = SmokingStatus.quit;
  late DateTime _quitDate;

  bool get _isEdit => widget.initialProfile != null;
  bool _unitsDefaulted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // New profiles start with the units that are normal in the phone's region.
    if (!_unitsDefaulted) {
      _unitsDefaulted = true;
      if (!_isEdit) _useImperial = Fmt.defaultsToImperial(Localizations.localeOf(context));
    }
  }

  @override
  void initState() {
    super.initState();
    final p = widget.initialProfile;
    final now = DateTime.now();
    _quitDate = widget.suggestedQuitDate ?? now;
    if (_quitDate.isAfter(now)) _quitDate = now;

    if (p != null) {
      _nameCtrl.text = p.displayName;
      _dob = p.dateOfBirth;
      _sex = p.sex;
      _heightCm = p.heightCm;
      _useImperial = p.useImperial;
      _status = p.smokingStatus;
      _quitDate = p.quitDate;
      if (p.cigarettesPerDay != null) _cigsCtrl.text = '${p.cigarettesPerDay}';
      if (p.yearsSmoked != null) _yearsCtrl.text = '${p.yearsSmoked}';
      if (p.pricePerPack != null) _priceCtrl.text = p.pricePerPack!.toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _nameCtrl.dispose();
    _cigsCtrl.dispose();
    _yearsCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ───────────────────────── Navigation / validation ─────────────────────────

  int? _parseInt(String s, int min, int max) {
    final v = int.tryParse(s.trim());
    if (v == null || v < min || v > max) return null;
    return v;
  }

  bool _validateCurrentPage() {
    final now = DateTime.now();
    switch (_page) {
      case 1:
        if (_dob == null) {
          _snack("Please choose your date of birth.");
          return false;
        }
        final probe = UserProfile(
          id: 'x',
          displayName: '',
          dateOfBirth: _dob!,
          sex: _sex,
          heightCm: _heightCm,
          useImperial: _useImperial,
          smokingStatus: _status,
          quitDate: now,
          createdAt: now,
        );
        if (probe.ageYears < UserProfile.minAge) {
          _snack("You must be at least ${UserProfile.minAge} years old to use this app.");
          return false;
        }
        if (probe.ageYears > 110) {
          _snack("Please check your date of birth.");
          return false;
        }
        return true;
      case 3:
        if (_status == SmokingStatus.planningToQuit && !_quitDate.isAfter(now)) {
          _snack("Pick a quit date in the future, or choose \"I've already quit\".");
          return false;
        }
        return true;
      case 4:
        if (_cigsCtrl.text.trim().isNotEmpty && _parseInt(_cigsCtrl.text, 1, 200) == null) {
          _snack("Cigarettes per day should be a number between 1 and 200.");
          return false;
        }
        if (_yearsCtrl.text.trim().isNotEmpty && _parseInt(_yearsCtrl.text, 0, 80) == null) {
          _snack("Years smoked should be a number between 0 and 80.");
          return false;
        }
        if (_priceCtrl.text.trim().isNotEmpty) {
          final price = double.tryParse(_priceCtrl.text.trim().replaceAll(',', '.'));
          if (price == null || price < 0 || price > 200) {
            _snack("Enter a valid price per pack (or leave it blank).");
            return false;
          }
        }
        return true;
      default:
        return true;
    }
  }

  void _next() {
    FocusScope.of(context).unfocus();
    if (!_validateCurrentPage()) return;
    if (_page == _lastPage) {
      _finish();
    } else {
      _controller.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  void _back() {
    FocusScope.of(context).unfocus();
    if (_page > 0) {
      _controller.previousPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  void _finish() {
    final now = DateTime.now();
    DateTime quit = _quitDate;
    if (_status == SmokingStatus.quit && quit.isAfter(now)) quit = now;

    final double? price = _priceCtrl.text.trim().isEmpty
        ? null
        : double.tryParse(_priceCtrl.text.trim().replaceAll(',', '.'));

    final profile = UserProfile(
      id: widget.initialProfile?.id ?? widget.profileId,
      displayName: _nameCtrl.text.trim(),
      dateOfBirth: _dob!,
      sex: _sex,
      heightCm: _heightCm,
      useImperial: _useImperial,
      smokingStatus: _status,
      quitDate: quit,
      cigarettesPerDay: _cigsCtrl.text.trim().isEmpty ? null : _parseInt(_cigsCtrl.text, 1, 200),
      yearsSmoked: _yearsCtrl.text.trim().isEmpty ? null : _parseInt(_yearsCtrl.text, 0, 80),
      pricePerPack: price,
      createdAt: widget.initialProfile?.createdAt ?? now,
    );
    widget.onComplete(profile);
  }

  // ───────────────────────── Pickers / formatting ─────────────────────────

  String _fmtDate(DateTime d) => Fmt.date(context, d);

  String _fmtDateTime(DateTime d) => Fmt.dateTime(context, d);

  String get _heightLabel {
    if (_useImperial) {
      final int totalIn = (_heightCm / 2.54).round();
      return "${totalIn ~/ 12}' ${totalIn % 12}\"";
    }
    return "${_heightCm.round()} cm";
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 35, 1, 1),
      firstDate: DateTime(now.year - 110, 1, 1),
      lastDate: now,
      helpText: "DATE OF BIRTH",
    );
    if (picked != null) setState(() => _dob = picked);
  }

  Future<void> _pickQuitDate() async {
    final now = DateTime.now();
    final bool planning = _status == SmokingStatus.planningToQuit;

    DateTime initial = _quitDate;
    if (!planning && initial.isAfter(now)) initial = now;
    if (planning && !initial.isAfter(now)) initial = now.add(const Duration(days: 1));

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: planning ? now : now.subtract(const Duration(days: 365 * 60)),
      lastDate: planning ? now.add(const Duration(days: 365)) : now,
      helpText: planning ? "PLANNED QUIT DATE" : "DATE YOU QUIT",
    );
    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_quitDate),
      helpText: planning ? "PLANNED QUIT TIME" : "TIME OF YOUR LAST CIGARETTE",
    );
    if (pickedTime == null) return;

    DateTime result = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );
    if (!planning && result.isAfter(now)) result = now;
    setState(() => _quitDate = result);
  }

  // ───────────────────────── Pages ─────────────────────────

  Widget _pageShell({
    required IconData icon,
    required String title,
    required String why,
    required List<Widget> children,
  }) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: Colors.teal.shade50,
            child: Icon(icon, color: Colors.teal.shade700, size: 28),
          ),
          const SizedBox(height: 16),
          Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(why, style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.35)),
          const SizedBox(height: 24),
          ...children,
        ],
      ),
    );
  }

  Widget _buildWelcomePage() {
    return _pageShell(
      icon: Icons.air_rounded,
      title: _isEdit ? "Your profile" : "Let's personalize AirEngine",
      why: "A few quick questions so your streak, savings and milestones fit you. "
          "You can change any of this later.",
      children: [
        TextField(
          controller: _nameCtrl,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: "What should we call you? (optional)",
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          "AirEngine provides wellness estimates only. It is not a medical device and "
          "is not a substitute for professional medical advice. Your data stays on this device.",
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.35),
        ),
      ],
    );
  }

  Widget _buildDobPage() {
    return _pageShell(
      icon: Icons.cake_rounded,
      title: "When were you born?",
      why: "Your age goes into the summary you can share with a clinician. It does not change "
          "your Breath Score, which compares you to your own baseline. We store your birth date so your "
          "age stays correct over time.",
      children: [
        OutlinedButton.icon(
          onPressed: _pickDob,
          icon: const Icon(Icons.calendar_today_rounded),
          label: Text(_dob == null ? "Choose date of birth" : _fmtDate(_dob!)),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
      ],
    );
  }

  Widget _buildBodyPage() {
    final bool imp = _useImperial;
    final double min = imp ? 48 : 120;
    final double max = imp ? 84 : 220;
    final double value = (imp ? _heightCm / 2.54 : _heightCm).clamp(min, max).roundToDouble();

    return _pageShell(
      icon: Icons.straighten_rounded,
      title: "Sex and height",
      why: "Sex and height appear in the clinician summary only. They do not change your Breath Score. "
          "\"Prefer not to say\" is fine.",
      children: [
        SegmentedButton<BiologicalSex>(
          segments: const [
            ButtonSegment(value: BiologicalSex.male, label: Text("Male")),
            ButtonSegment(value: BiologicalSex.female, label: Text("Female")),
            ButtonSegment(value: BiologicalSex.unspecified, label: Text("Prefer not to say")),
          ],
          selected: {_sex},
          onSelectionChanged: (s) => setState(() => _sex = s.first),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_heightLabel, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text("ft / in")),
                ButtonSegment(value: false, label: Text("cm")),
              ],
              selected: {_useImperial},
              onSelectionChanged: (s) => setState(() => _useImperial = s.first),
            ),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: (max - min).round(),
          label: _heightLabel,
          onChanged: (v) => setState(() => _heightCm = imp ? v * 2.54 : v),
        ),
      ],
    );
  }

  Widget _buildQuitPage() {
    final bool planning = _status == SmokingStatus.planningToQuit;

    return _pageShell(
      icon: Icons.smoke_free_rounded,
      title: "Your quit date",
      why: "This starts your smoke-free streak and your health milestones.",
      children: [
        RadioGroup<SmokingStatus>(
          groupValue: _status,
          onChanged: (SmokingStatus? v) {
            if (v == null) return;
            setState(() {
              _status = v;
              if (v == SmokingStatus.quit) {
                if (_quitDate.isAfter(DateTime.now())) _quitDate = DateTime.now();
              } else if (!_quitDate.isAfter(DateTime.now())) {
                _quitDate = DateTime.now().add(const Duration(days: 1));
              }
            });
          },
          child: const Column(
            children: [
              RadioListTile<SmokingStatus>(
                value: SmokingStatus.quit,
                title: Text("I've already quit"),
                subtitle: Text("Count from my last cigarette"),
              ),
              RadioListTile<SmokingStatus>(
                value: SmokingStatus.planningToQuit,
                title: Text("I plan to quit"),
                subtitle: Text("Streak starts on my chosen date"),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _pickQuitDate,
          icon: const Icon(Icons.event_rounded),
          label: Text(_fmtDateTime(_quitDate)),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
        const SizedBox(height: 8),
        Text(
          planning
              ? "Your streak will show 0 until this date."
              : "Slip-ups you log later reset the streak from that moment.",
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _buildHistoryPage() {
    return _pageShell(
      icon: Icons.history_rounded,
      title: "Smoking history",
      why: "Optional. Used to show cigarettes avoided and money saved. "
          "Leave blank to skip.",
      children: [
        TextField(
          controller: _cigsCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: "Cigarettes per day (optional)",
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _yearsCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: "Years smoked (optional)",
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _priceCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: "Price per pack of 20 (optional)",
            prefixText: "${Fmt.currencySymbol(context)} ",
            border: const OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  // ───────────────────────── Build ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final bool isLast = _page == _lastPage;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? "Edit profile" : "Set up your profile"),
        backgroundColor: Colors.teal.shade100,
        automaticallyImplyLeading: _isEdit,
      ),
      body: SafeArea(
        child: Column(
          children: [
            LinearProgressIndicator(
              value: (_page + 1) / (_lastPage + 1),
              minHeight: 4,
              backgroundColor: Colors.teal.shade50,
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  _buildWelcomePage(),
                  _buildDobPage(),
                  _buildBodyPage(),
                  _buildQuitPage(),
                  _buildHistoryPage(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  if (_page > 0)
                    TextButton(onPressed: _back, child: const Text("Back"))
                  else
                    const SizedBox(width: 64),
                  const Spacer(),
                  ElevatedButton(
                    onPressed: _next,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal.shade700,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(120, 48),
                    ),
                    child: Text(isLast ? (_isEdit ? "Save" : "Finish") : "Next"),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}