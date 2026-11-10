import 'dart:async';

import 'package:fl_clash/common/freev6.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryStorage extends FreeV6Storage {
  String? credentials;
  bool failWrite = false;
  bool failRead = false;

  @override
  Future<String?> read() async {
    if (failRead) throw StateError('Keystore unavailable');
    return credentials;
  }

  @override
  Future<void> write(String value) async {
    if (failWrite) throw StateError('Storage unavailable');
    credentials = value;
  }
}

class RecordingCore implements CoreHandlerInterface {
  int registrations = 0;
  final profiles = <Map<String, dynamic>>[];
  Completer<void>? registrationGate;
  String response = '{"proxies":[]}';

  @override
  Future<Object?> invokeMethod({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async {
    if (method == CoreMethod.freeV6Register) {
      registrations++;
      await registrationGate?.future;
      return 'registered-credentials';
    }
    if (method == CoreMethod.freeV6Profile) {
      profiles.add(Map<String, dynamic>.from(arguments! as Map));
      return response;
    }
    throw StateError('Unexpected method');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'registers once and reuses credentials when campus rules change',
    () async {
      final core = RecordingCore();
      final storage = MemoryStorage();
      await FreeV6Preparation(core, storage).prepare(['campus.example']);
      await FreeV6Preparation(core, storage).prepare(['2001:db8::/32']);
      expect(core.registrations, 1);
      expect(storage.credentials, 'registered-credentials');
      expect(core.profiles.last, {
        'credentials': 'registered-credentials',
        'campus-targets': ['2001:db8::/32'],
      });
    },
  );

  test(
    'retries saving pending credentials without registering again',
    () async {
      final core = RecordingCore();
      final storage = MemoryStorage()..failWrite = true;
      final preparation = FreeV6Preparation(core, storage);
      await expectLater(preparation.prepare([]), throwsStateError);
      expect(core.profiles, isEmpty);
      storage.failWrite = false;
      await preparation.prepare([]);
      expect(core.registrations, 1);
      expect(storage.credentials, 'registered-credentials');
    },
  );

  test('a decryption failure never replaces the existing account', () async {
    final core = RecordingCore();
    final storage = MemoryStorage()..failRead = true;
    await expectLater(
      FreeV6Preparation(core, storage).prepare([]),
      throwsStateError,
    );
    expect(core.registrations, 0);
    expect(core.profiles, isEmpty);
  });

  test('rejects overlapping registrations', () async {
    final core = RecordingCore()..registrationGate = Completer<void>();
    final preparation = FreeV6Preparation(core, MemoryStorage());
    final first = preparation.prepare([]);
    await expectLater(preparation.prepare([]), throwsStateError);
    core.registrationGate!.complete();
    await first;
    expect(core.registrations, 1);
  });

  test(
    'a malformed profile is rejected and saved credentials remain',
    () async {
      final core = RecordingCore()..response = '{}';
      final storage = MemoryStorage();
      await expectLater(
        FreeV6Preparation(core, storage).prepare([]),
        throwsFormatException,
      );
      expect(storage.credentials, 'registered-credentials');
    },
  );
}
