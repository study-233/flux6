import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/l10n.dart';

class PreviewUiStrings extends UiLocalizations {
  @override
  String get back => '返回';
  @override
  String get cancel => '取消';
  @override
  String get clearSearch => '清除搜索';
  @override
  String get close => '关闭';
  @override
  String get copy => '复制';
  @override
  String get cut => '剪切';
  @override
  String get dialog => '对话框';
  @override
  String get hidePassword => '隐藏密码';
  @override
  String get more => '更多';
  @override
  String get noSearchResults => '没有搜索结果';
  @override
  String get paste => '粘贴';
  @override
  String get reset => '重置';
  @override
  String get select => '选择';
  @override
  String get search => '搜索';
  @override
  String get selectAll => '全选';
  @override
  String get showLess => '收起';
  @override
  String get showMore => '展开';
  @override
  String get showPassword => '显示密码';
  @override
  String get sort => '排序';
  @override
  String get submit => '提交';
}

class PrismStringsDelegate extends LocalizationsDelegate<UiLocalizations> {
  const PrismStringsDelegate();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<UiLocalizations> load(Locale locale) =>
      SynchronousFuture(PreviewUiStrings());
  @override
  bool shouldReload(PrismStringsDelegate old) => false;
}
