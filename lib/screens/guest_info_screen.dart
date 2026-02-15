// Join as guest: name, age, gender. Saved locally so we can recognize them next time.

import 'package:flutter/material.dart';
import '../services/guest_profile_service.dart';
import 'join_party_screen.dart';

class GuestInfoScreen extends StatefulWidget {
  const GuestInfoScreen({
    super.key,
    this.onBack,
  });

  final VoidCallback? onBack;

  @override
  State<GuestInfoScreen> createState() => _GuestInfoScreenState();
}

class _GuestInfoScreenState extends State<GuestInfoScreen> {
  GuestProfileService? _service;
  GuestProfile? _profile;
  final _nameController = TextEditingController();
  final _ageController = TextEditingController();
  String _gender = '';
  bool _saving = false;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    GuestProfileService.create().then((s) {
      if (mounted) {
        setState(() {
          _service = s;
          _profile = s.getProfile();
          if (_profile!.hasProfile) {
            _nameController.text = _profile!.name;
            _ageController.text = _profile!.age > 0 ? '${_profile!.age}' : '';
            _gender = _profile!.gender;
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _ageController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_service == null) return;
    if (!_formKey.currentState!.validate()) return;

    final name = _nameController.text.trim();
    final age = int.tryParse(_ageController.text.trim()) ?? 0;
    if (name.isEmpty || age <= 0 || _gender.isEmpty) return;

    setState(() => _saving = true);
    await _service!.saveProfile(name: name, age: age, gender: _gender);
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => JoinPartyScreen(onBack: widget.onBack),
      ),
    );
  }

  void _continueToJoin() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => JoinPartyScreen(onBack: widget.onBack),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isReturning = _profile != null && _profile!.hasProfile;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Join as guest'),
        leading: widget.onBack != null
            ? IconButton(icon: const Icon(Icons.close), onPressed: widget.onBack)
            : null,
      ),
      body: _service == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (isReturning) ...[
                      Text(
                        'Welcome back, ${_profile!.name}!',
                        style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'We’ll remember you next time you join a party.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 32),
                      FilledButton(
                        onPressed: _continueToJoin,
                        child: const Text('Continue to add songs'),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () async {
                          await _service?.clearProfile();
                          if (mounted) setState(() => _profile = _service?.getProfile());
                        },
                        child: const Text('Use a different name'),
                      ),
                    ] else ...[
                      Text(
                        'Tell us a bit about you',
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Saved only on this device. We’ll recognize you next time you join.',
                        style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          hintText: 'Your name',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return 'Enter your name';
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _ageController,
                        decoration: const InputDecoration(
                          labelText: 'Age',
                          hintText: 'e.g. 25',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          final n = int.tryParse(v ?? '');
                          if (n == null || n < 1 || n > 120) return 'Enter a valid age';
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      const Text('Gender', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 8),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'Male', label: Text('Male')),
                          ButtonSegment(value: 'Female', label: Text('Female')),
                          ButtonSegment(value: 'Other', label: Text('Other')),
                        ],
                        selected: _gender.isEmpty ? <String>{} : {_gender},
                        onSelectionChanged: (s) => setState(() => _gender = s.isNotEmpty ? s.first : ''),
                        emptySelectionAllowed: true,
                      ),
                      if (_gender.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Select gender',
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                          ),
                        ),
                      const SizedBox(height: 32),
                      FilledButton(
                        onPressed: _saving ? null : _submit,
                        child: _saving
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Continue'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}
