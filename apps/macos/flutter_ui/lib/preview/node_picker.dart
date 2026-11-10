import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:prism_ui/press_surface.dart';

import 'fixture_model.dart';

Future<void> showFixtureNodePicker(BuildContext context, FixtureModel model) {
  return showDialog<void>(
    context: context,
    builder: (_) => _NodePicker(model: model),
  );
}

class NodeSearchField extends StatelessWidget {
  const NodeSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: '搜索节点',
        prefixIcon: const Icon(Icons.search_rounded, size: 19),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: '清除搜索',
                icon: const Icon(Icons.close_rounded, size: 16),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        filled: true,
        fillColor: Theme.of(context).colorScheme.surfaceContainerHighest
            .withValues(alpha: .5),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

/// The row's press target selects a node. Its trailing delay action is a
/// separate sibling so a test never changes the current selection.
class FixtureNodeRow extends StatelessWidget {
  const FixtureNodeRow({
    super.key,
    required this.model,
    required this.node,
    this.onSelected,
    this.highlighted = false,
    this.allowMeasure = true,
  });

  final FixtureModel model;
  final String? node;
  final VoidCallback? onSelected;
  final bool highlighted;
  final bool allowMeasure;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final item = node;
    final selected = model.preferredNode == item;
    final active = item != null && model.currentNode == item;
    final name = item ?? '自动选择';
    final status = item == null
        ? '根据可用节点选择'
        : active
        ? selected
              ? '使用中 · 首选'
              : '使用中'
        : selected
        ? '下次连接 · 预选'
        : '校园 IPv6';
    final background = highlighted || selected
        ? colors.primary.withValues(alpha: .10)
        : colors.surface;
    final radius = BorderRadius.circular(18);
    void choose() {
      model.selectNode(item);
      onSelected?.call();
    }

    return DecoratedBox(
      decoration: BoxDecoration(color: background, borderRadius: radius),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              enabled: !model.busy,
              selected: selected,
              excludeSemantics: true,
              label: '$name，$status',
              onTap: model.busy ? null : choose,
              child: PressSurface(
                fill: Colors.transparent,
                shape: RoundedRectangleBorder(borderRadius: radius),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                onPressed: model.busy ? null : choose,
                child: Row(
                  children: [
                    ExcludeSemantics(
                      child: Icon(
                        selected
                            ? Icons.check_circle
                            : item == null
                            ? Icons.auto_awesome_outlined
                            : Icons.lan_outlined,
                        size: 19,
                        color: selected
                            ? colors.primary
                            : colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: active
                                  ? colors.primary
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (allowMeasure && item != null && model.connected) ...[
            Text(
              model.latency(item) == null ? '未测' : '${model.latency(item)} ms',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            IconButton(
              tooltip: '测量${item}延迟',
              onPressed: model.measuring(item)
                  ? null
                  : () => model.measure(item),
              icon: model.measuring(item)
                  ? const SizedBox.square(
                      dimension: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.speed_rounded, size: 19),
            ),
            const SizedBox(width: 4),
          ],
        ],
      ),
    );
  }
}

class _NodePicker extends StatefulWidget {
  const _NodePicker({required this.model});
  final FixtureModel model;

  @override
  State<_NodePicker> createState() => _NodePickerState();
}

class _NodePickerState extends State<_NodePicker> {
  final _search = TextEditingController();
  int _index = 0;

  @override
  void initState() {
    super.initState();
    final currentIndex = _visible.indexOf(widget.model.preferredNode);
    if (currentIndex >= 0) _index = currentIndex;
  }

  List<String?> get _visible {
    final query = _search.text.trim();
    return [
      if ('自动选择'.contains(query)) null,
      ...widget.model.nodes.where((node) => node.contains(query)),
    ];
  }

  void _move(int step) {
    if (_visible.isEmpty) return;
    setState(() => _index = (_index + step).clamp(0, _visible.length - 1));
  }

  void _commit() {
    final items = _visible;
    if (items.isEmpty || widget.model.busy) return;
    widget.model.selectNode(items[_index.clamp(0, items.length - 1)]);
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 430, maxHeight: 442),
        child: ListenableBuilder(
          listenable: model,
          builder: (context, _) {
            final visible = _visible;
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '选择接入节点',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                          _move(1),
                      const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                          _move(-1),
                    },
                    child: NodeSearchField(
                      controller: _search,
                      autofocus: true,
                      onChanged: (_) => setState(() => _index = 0),
                      onSubmitted: (_) => _commit(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (visible.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(18),
                      child: Text('没有匹配的节点', textAlign: TextAlign.center),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: visible.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 3),
                        itemBuilder: (context, index) => FixtureNodeRow(
                          model: model,
                          node: visible[index],
                          highlighted: _index == index,
                          allowMeasure: false,
                          onSelected: () => Navigator.of(context).pop(),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
