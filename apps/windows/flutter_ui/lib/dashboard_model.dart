import 'package:flutter/foundation.dart';

class PreviewLog {
  const PreviewLog(this.time, this.message, {this.level = '信息'});

  final DateTime time;
  final String message;
  final String level;

  Map<String, Object> toJson() => {
    'time': time.toIso8601String(),
    'message': message,
    'level': level,
  };

  static PreviewLog? fromJson(Object? value) {
    if (value is! Map) return null;
    final time = DateTime.tryParse(value['time']?.toString() ?? '');
    final message = value['message'];
    if (time == null || message is! String || message.isEmpty) return null;
    return PreviewLog(
      time.toLocal(),
      message,
      level: value['level'] == '警告' ? '警告' : '信息',
    );
  }
}

/// Read model shared by the isolated visual preview and the native host.
abstract class DashboardModel extends ChangeNotifier {
  static const modeNames = ['规则', '全局', '直连'];
  String get mode;
  String get profileName;
  bool get monthly;
  bool get connected;
  bool get busy;
  bool get canConnectAction => !busy;
  bool get canChangeMode => !busy;
  bool get canSelectNode => !busy;
  bool get canMeasure => connected && !busy;
  String get phaseLabel;
  String? get actionLabel => null;
  String get displayNode;
  String? get preferredNode;
  String? get currentNode;
  Duration get uptime;
  bool get uptimeKnown => connected;
  String? get modeHint => null;
  List<String> get nodes;
  ValueNotifier<int> get traffic;
  List<double> get uploadHistory;
  List<double> get downloadHistory;
  int get usageUpload;
  int get usageDownload;
  bool get usageKnown => true;
  List<PreviewLog> get logs;
  List<Map<String, dynamic>>? get customLayout => null;
  int? latency(String node);
  bool measuring(String node);
  void selectMode(String value);
  void selectNode(String? node);
  void setMonthly(bool value);
  Future<void> toggleConnection();
  Future<void> measure(String node);
}
