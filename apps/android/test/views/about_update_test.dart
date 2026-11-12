import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/about.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_app.dart';

class _UpdateAdapter implements HttpClientAdapter {
  final response = Completer<ResponseBody>();
  final paths = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    paths.add(options.uri.toString());
    return response.future;
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  for (final width in [390.0, 900.0]) {
    for (final dark in [false, true]) {
      testWidgets('manual update on $width dp, dark=$dark, checks once', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        globalState.packageInfo = PackageInfo(
          appName: 'Flux6',
          packageName: 'dev.freev6.mobile',
          version: '0.1.1',
          buildNumber: '2026111101',
        );
        final container = ProviderContainer();
        addTearDown(container.dispose);
        globalState.container = container;
        container.listen(appSettingProvider, (_, _) {}, fireImmediately: true);
        container
            .read(appSettingProvider.notifier)
            .update((state) => state.copyWith(autoCheckUpdate: false));
        container
            .read(viewSizeProvider.notifier)
            .update((_) => Size(width, 844));
        final adapter = _UpdateAdapter();
        final original = request.releaseDio.httpClientAdapter;
        request.releaseDio.httpClientAdapter = adapter;
        addTearDown(() => request.releaseDio.httpClientAdapter = original);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: TestApp(
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              child: const AboutView(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          await container.read(commonActionProvider.notifier).autoCheckUpdate(),
          isFalse,
        );
        expect(adapter.paths, isEmpty);
        final button = find.text('Check for updates');
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(button);
        await tester.pump(const Duration(milliseconds: 300));
        expect(adapter.paths, [
          'https://api.github.com/repos/study-233/flux6/releases/latest',
        ]);
        expect(container.read(loadingProvider(LoadingTag.checkUpdate)), isTrue);
        expect(find.byType(ActivityIndicator), findsOneWidget);
        adapter.response.complete(
          ResponseBody.fromString(
            '{"tag_name":"v0.1.1"}',
            200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('The app is already up to date'), findsOneWidget);
        expect(container.read(appSettingProvider).autoCheckUpdate, isFalse);
        await tester.tap(find.byType(TextButton).last);
        await tester.pumpAndSettle();
        expect(
          container.read(loadingProvider(LoadingTag.checkUpdate)),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
