import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/freev6.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum FreeV6ViewMode { onboarding, setup, diagnostics }

class FreeV6View extends ConsumerStatefulWidget {
  const FreeV6View({super.key, this.mode = FreeV6ViewMode.setup});

  final FreeV6ViewMode mode;

  @override
  ConsumerState<FreeV6View> createState() => _FreeV6ViewState();
}

class _FreeV6ViewState extends ConsumerState<FreeV6View> {
  final _campus = TextEditingController();
  final _storage = const FreeV6Storage();
  late final FreeV6Preparation _preparation;
  late int _step;
  bool _busy = false;
  bool _ready = false;
  bool _details = false;
  bool _advanced = false;
  String? _message;
  Map<String, dynamic>? _network;

  bool get _diagnostics => widget.mode == FreeV6ViewMode.diagnostics;
  bool get _networkReady =>
      _network?['wifi'] == true &&
      _network?['hasAddress'] == true &&
      _network?['defaultRoute'] == true;

  @override
  void initState() {
    super.initState();
    _step = widget.mode == FreeV6ViewMode.onboarding ? 0 : 1;
    _preparation = FreeV6Preparation(ref.read(coreHandlerProvider), _storage);
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      _campus.text = prefs.getString('freev6.campus') ?? '';
      setState(() {
        _advanced = _campus.text.isNotEmpty;
        _ready = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _message = context.appLocalizations.freev6PrepareFailed);
      }
    }
  }

  String? _networkIssue(Map<String, dynamic> network) {
    final strings = context.appLocalizations;
    if (network['wifi'] != true) return strings.freev6NetworkRequired;
    if (network['hasAddress'] != true) return strings.freev6NoIpv6Address;
    if (network['defaultRoute'] != true) return strings.freev6NoIpv6Route;
    return null;
  }

  Future<void> _checkNetwork() async {
    if (_busy || !_ready) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final network = await _storage.network(probe: true);
      if (!mounted) return;
      setState(() {
        _network = network;
        _message = _networkIssue(network);
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _network = null;
          _message = context.appLocalizations.freev6NetworkCheckFailed;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare() async {
    if (_busy || !_ready) return;
    final strings = context.appLocalizations;
    final core = ref.read(coreHandlerProvider);
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final network = await _storage.network();
      if (!mounted) return;
      final issue = _networkIssue(network);
      if (issue != null) {
        setState(() {
          _step = 1;
          _network = network;
        });
        throw MessageException(issue);
      }
      final campus = _campus.text.trim();
      final targets = campus
          .split(RegExp(r'[\s,，]+'))
          .where((s) => s.isNotEmpty)
          .toList();
      final profileJson = await _preparation.prepare(targets);
      final yaml = await encodeYamlTask(jsonDecode(profileJson));
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final savedId = prefs.getInt('freev6.profileId');
      final existing = ref
          .read(profilesProvider)
          .where((p) => p.id == savedId)
          .firstOrNull;
      final profile = existing ?? Profile.normal(label: 'FreeV6 WARP');
      final prepared = await profile.saveFile(
        Uint8List.fromList(utf8.encode(yaml)),
        validate: (path, key) => core.validateProfile(path, key),
      );
      if (!mounted) return;
      ref
          .read(profilesActionProvider.notifier)
          .putProfile(prepared.copyWith(autoUpdate: false));
      ref
          .read(vpnSettingProvider.notifier)
          .update((state) => state.copyWith(ipv6: true));
      ref.read(currentProfileIdProvider.notifier).value = prepared.id;
      await prefs.setInt('freev6.profileId', prepared.id);
      await prefs.setString('freev6.campus', campus);
      if (!mounted) return;
      final applied = await ref
          .read(setupActionProvider.notifier)
          .applyProfile(force: true);
      if (!applied) throw MessageException(strings.freev6PrepareFailed);
      if (mounted) setState(() => _step = 3);
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error is MessageException
              ? error.message
              : strings.freev6PrepareFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _next() {
    setState(() {
      _step++;
      _message = null;
    });
  }

  void _back() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _step--;
      _message = null;
    });
  }

  void _openHome() {
    ref.read(currentPageLabelProvider.notifier).toPage(PageLabel.dashboard);
    Navigator.of(context).pop();
  }

  Widget _hero(Glyph glyph, String title, String description) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 20,
    children: [
      ExcludeSemantics(
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: AppShape.xl,
            color: context.raisedSurfaceLevel.colorOf(context.colorScheme),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: GlyphIcon(
              glyph,
              size: 40,
              color: context.colorScheme.primary,
            ),
          ),
        ),
      ),
      Text(title, style: AppTextStyle.title1.of(context, emphasized: true)),
      Text(description, style: AppTextStyle.body.of(context)),
    ],
  );

  List<Widget> _content() {
    final strings = context.appLocalizations;
    switch (_step) {
      case 0:
        return [
          _hero(
            AppGlyphs.proxies,
            strings.freev6WelcomeTitle,
            strings.freev6WelcomeBody,
          ),
          const SizedBox(height: 32),
          Card(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 20,
              children: [
                _guideRow(AppGlyphs.wifi, strings.freev6StepNetwork),
                _guideRow(AppGlyphs.profiles, strings.freev6StepPrepare),
                _guideRow(AppGlyphs.checkCircle, strings.freev6StepDone),
              ],
            ),
          ),
        ];
      case 1:
        return [
          _hero(
            AppGlyphs.wifi,
            strings.freev6StepNetwork,
            strings.freev6NetworkGuide,
          ),
          const SizedBox(height: 24),
          Card(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _busy
                        ? strings.freev6CheckingNetwork
                        : _networkReady
                        ? _network!['reachable'] == true
                              ? strings.freev6WifiReady
                              : strings.freev6WifiUnverified
                        : strings.freev6WifiWaiting,
                    style: AppTextStyle.headline.of(context),
                  ),
                ),
                if (_networkReady)
                  Text(
                    strings.freev6NetworkContinue,
                    style: AppTextStyle.subheadline.of(context),
                  ),
                if (_network != null) ...[
                  TextButton(
                    onPressed: () => setState(() => _details = !_details),
                    child: Text(
                      _details
                          ? strings.freev6HideDetails
                          : strings.freev6ShowDetails,
                    ),
                  ),
                  if (_details) ...[
                    if ((_network!['addresses'] as List<dynamic>? ?? [])
                        .isNotEmpty)
                      SelectableText(
                        strings.freev6Ipv6Addresses(
                          (_network!['addresses'] as List<dynamic>).join('\n'),
                        ),
                        style: AppTextStyle.subheadline.of(context),
                      ),
                    if (_networkReady)
                      Text(
                        _network!['reachable'] == true
                            ? strings.freev6ProbePassed
                            : strings.freev6ProbeFailed,
                        style: AppTextStyle.subheadline.of(context),
                      ),
                  ],
                ],
              ],
            ),
          ),
          if (_network != null && !_diagnostics)
            TextButton(
              onPressed: _busy ? null : _checkNetwork,
              child: Text(strings.freev6CheckNetwork),
            ),
        ];
      case 2:
        return [
          _hero(
            AppGlyphs.profiles,
            strings.freev6StepPrepare,
            strings.freev6PrepareGuide,
          ),
          const SizedBox(height: 24),
          Card(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _advanced = !_advanced),
                  child: Text(strings.freev6CampusOptions),
                ),
                if (_advanced) ...[
                  Text(
                    strings.freev6Campus,
                    style: AppTextStyle.subheadline.of(context),
                  ),
                  Semantics(
                    label: strings.freev6Campus,
                    child: TextField(
                      controller: _campus,
                      enabled: !_busy,
                      autocorrect: false,
                      minLines: 1,
                      maxLines: 4,
                    ),
                  ),
                ] else
                  Text(
                    strings.freev6CampusOptional,
                    style: AppTextStyle.subheadline.of(context),
                  ),
              ],
            ),
          ),
        ];
      default:
        return [
          _hero(
            AppGlyphs.checkCircle,
            strings.freev6StepDone,
            strings.freev6DoneGuide,
          ),
          const SizedBox(height: 24),
          Text(strings.freev6ToolsHint, style: AppTextStyle.body.of(context)),
        ];
    }
  }

  Widget _guideRow(Glyph glyph, String text) => Row(
    spacing: 16,
    children: [
      ExcludeSemantics(
        child: GlyphIcon(glyph, color: context.colorScheme.primary),
      ),
      Expanded(child: Text(text, style: AppTextStyle.body.of(context))),
    ],
  );

  Widget _actions() {
    final strings = context.appLocalizations;
    final (label, action) = switch (_step) {
      0 => (strings.freev6StartSetup, _next),
      1 when !_diagnostics && _networkReady => (strings.freev6Continue, _next),
      1 => (
        _busy ? strings.freev6CheckingNetwork : strings.freev6CheckNetwork,
        _checkNetwork,
      ),
      2 => (_busy ? strings.freev6Preparing : strings.freev6Prepare, _prepare),
      _ => (strings.freev6OpenHome, _openHome),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        FilledButton(
          onPressed: _busy || !_ready ? null : action,
          child: Text(label),
        ),
        if (_step == 0)
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(strings.freev6SkipSetup),
          ),
        if (_step == 2)
          TextButton(
            onPressed: _busy ? null : _back,
            child: Text(strings.freev6Previous),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _campus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.appLocalizations;
    return KeyboardInsetHold(
      child: PopScope(
        canPop: !_busy,
        child: Scaffold(
          title: _diagnostics
              ? strings.freev6NetworkTitle
              : strings.freev6SetupTitle,
          body: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  key: ValueKey(_step),
                  padding: EdgeInsets.fromLTRB(
                    24,
                    context.contentTopPadding,
                    24,
                    24,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!_diagnostics && _step > 0) ...[
                            Text(
                              strings.freev6StepCount(_step),
                              style: AppTextStyle.footnote.of(context),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              spacing: 8,
                              children: [
                                for (var i = 1; i <= 3; i++)
                                  Expanded(
                                    child: SizedBox(
                                      height: 4,
                                      child: DecoratedBox(
                                        decoration: ShapeDecoration(
                                          shape: AppShape.md,
                                          color: i <= _step
                                              ? context.colorScheme.primary
                                              : context
                                                    .colorScheme
                                                    .surfaceContainerHighest,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 24),
                          ],
                          ..._content(),
                          if (_message case final message?) ...[
                            const SizedBox(height: 20),
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                message,
                                style: AppTextStyle.body.of(context),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: _actions(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
