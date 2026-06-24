import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../util/palette.dart';

class SliderNumberField extends StatefulWidget {
  final int value;
  final int min;
  final int max;
  final int step;

  /// Formats the raw int value for display (label below slider and input field).
  final String Function(int) labelBuilder;

  /// Parses a human-readable string back to raw int.
  /// Return null to reject the input and revert.
  final int? Function(String)? inputParser;

  final ValueChanged<int> onChanged;

  const SliderNumberField({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.labelBuilder,
    required this.onChanged,
    this.inputParser,
  });

  @override
  State<SliderNumberField> createState() => _SliderNumberFieldState();
}

class _SliderNumberFieldState extends State<SliderNumberField> {
  late final TextEditingController _ctrl;
  late int _current;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _current = widget.value.clamp(widget.min, widget.max);
    _ctrl = TextEditingController(text: widget.labelBuilder(_current));
  }

  @override
  void didUpdateWidget(SliderNumberField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_editing) {
      _current = widget.value.clamp(widget.min, widget.max);
      _ctrl.text = widget.labelBuilder(_current);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onSlider(double v) {
    final snapped = _snap(v.round());
    setState(() => _current = snapped);
    _ctrl.text = widget.labelBuilder(snapped);
    widget.onChanged(snapped);
  }

  void _onInputSubmit(String raw) {
    setState(() => _editing = false);
    final parser = widget.inputParser ?? (s) => int.tryParse(s.trim());
    final parsed = parser(raw);
    if (parsed == null) {
      _ctrl.text = widget.labelBuilder(_current);
      return;
    }
    final clamped = parsed.clamp(widget.min, widget.max);
    final snapped = _snap(clamped);
    setState(() => _current = snapped);
    _ctrl.text = widget.labelBuilder(snapped);
    widget.onChanged(snapped);
  }

  int _snap(int v) {
    if (widget.step <= 1) return v;
    return ((v - widget.min) / widget.step).round() * widget.step + widget.min;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Slider(
            value: _current.toDouble(),
            min: widget.min.toDouble(),
            max: widget.max.toDouble(),
            divisions: widget.step > 0
                ? ((widget.max - widget.min) / widget.step).round()
                : null,
            onChanged: _onSlider,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        SizedBox(
          width: 88,
          child: TextField(
            controller: _ctrl,
            keyboardType: TextInputType.text,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9a-zA-Z.\s]'))],
            style: AppTextStyles.dataDisplay,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.base,
              ),
              filled: true,
              fillColor: AppColors.surfaceContainerHigh,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.def),
                borderSide: const BorderSide(color: AppColors.outlineVariant),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.def),
                borderSide: const BorderSide(color: AppColors.outlineVariant),
              ),
            ),
            onTap: () {
              setState(() => _editing = true);
              _ctrl.selectAll();
            },
            onSubmitted: _onInputSubmit,
            onTapOutside: (_) => _onInputSubmit(_ctrl.text),
          ),
        ),
      ],
    );
  }
}

extension on TextEditingController {
  void selectAll() {
    selection = TextSelection(baseOffset: 0, extentOffset: text.length);
  }
}
