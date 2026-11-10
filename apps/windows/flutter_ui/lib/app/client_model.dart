import 'dart:convert';

import '../dashboard_model.dart';

typedef JsonMap = Map<String, dynamic>;

abstract class ClientModel extends DashboardModel {
  Stream<String> get events => const Stream.empty();
  bool get preview;
  String? get message;
  void dismissMessage();
  JsonMap get settings;
  Map<String, String> get preferences;
  JsonMap get chain;
  JsonMap get cloud;
  JsonMap get runtime;
  JsonMap get coreDownload;
  JsonMap get update;
  List<JsonMap> get notices;
  Set<String> get readNoticeIds {
    try {
      final value = jsonDecode(preference('freev6-notice-read', '[]'));
      return value is List ? value.whereType<String>().toSet() : {};
    } on FormatException {
      return {};
    }
  }

  int get unreadNotices =>
      notices.where((n) => !readNoticeIds.contains(n['id']?.toString())).length;
  String get proxyTab;
  bool pending(String action);
  bool setting(String field) => settings[field] == true;
  @override
  bool get allowDirectMode => setting('devMode');
  String preference(String field, [String fallback = '']) =>
      preferences[field] ?? fallback;

  /// Returns false after surfacing a user-facing failure; forms retain drafts.
  Future<bool> act(String action, [JsonMap arguments = const {}]);
}
