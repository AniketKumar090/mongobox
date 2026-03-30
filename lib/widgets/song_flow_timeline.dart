import 'package:flutter/material.dart';

/// A slim, inline step-progress indicator that stretches full width.
///
/// Usage:
///   SongFlowTimeline(currentStep: 1)  // step 1 = Song, 2 = Voice, 3 = Preview
class SongFlowTimeline extends StatelessWidget {
  const SongFlowTimeline({
    super.key,
    required this.currentStep,
    this.labels = const ['Song', 'Voice', 'Preview'],
  }) : assert(labels.length >= 2, 'SongFlowTimeline needs at least 2 steps.');

  final int currentStep;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final safeStep = currentStep.clamp(1, labels.length);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 360;
        final markerSize = compact ? 18.0 : 22.0;
        final lineHeight = compact ? 2.0 : 2.4;
        final fullLineWidth = (constraints.maxWidth - markerSize).clamp(
          0.0,
          double.infinity,
        );
        final segmentWidth =
            labels.length > 1 ? fullLineWidth / (labels.length - 1) : 0.0;
        final activeLineWidth = segmentWidth * (safeStep - 1);

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: markerSize,
              width: double.infinity,
              child: Stack(
                children: [
                  Positioned(
                    left: markerSize / 2,
                    right: markerSize / 2,
                    top: (markerSize - lineHeight) / 2,
                    child: Container(
                      height: lineHeight,
                      color: const Color(0xFFD8D4CC),
                    ),
                  ),
                  if (activeLineWidth > 0)
                    Positioned(
                      left: markerSize / 2,
                      top: (markerSize - lineHeight) / 2,
                      width: activeLineWidth,
                      child: Container(
                        height: lineHeight,
                        color: const Color(0xFF111111),
                      ),
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: List.generate(labels.length, (index) {
                      final stepNumber = index + 1;
                      final isCurrent = stepNumber == safeStep;
                      final isCompleted = stepNumber < safeStep;

                      return _StepMarker(
                        stepNumber: stepNumber,
                        isCurrent: isCurrent,
                        isCompleted: isCompleted,
                        size: markerSize,
                      );
                    }),
                  ),
                ],
              ),
            ),
            SizedBox(height: compact ? 6 : 8),
            Row(
              children: List.generate(labels.length, (index) {
                final stepNumber = index + 1;
                final isCurrent = stepNumber == safeStep;
                final isCompleted = stepNumber < safeStep;
                final alignment =
                    index == 0
                        ? Alignment.centerLeft
                        : index == labels.length - 1
                        ? Alignment.centerRight
                        : Alignment.center;

                return Expanded(
                  child: Align(
                    alignment: alignment,
                    child: Text(
                      labels[index],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: compact ? 11 : 12,
                        fontWeight:
                            isCurrent
                                ? FontWeight.w800
                                : isCompleted
                                ? FontWeight.w700
                                : FontWeight.w600,
                        color:
                            isCurrent || isCompleted
                                ? const Color(0xFF444444)
                                : const Color(0xFFAAAAAA),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        );
      },
    );
  }
}

class _StepMarker extends StatelessWidget {
  const _StepMarker({
    required this.stepNumber,
    required this.isCurrent,
    required this.isCompleted,
    required this.size,
  });

  final int stepNumber;
  final bool isCurrent;
  final bool isCompleted;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (isCompleted) {
      return Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Color(0xFF111111),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.check_rounded, color: Colors.white, size: size * 0.6),
      );
    }

    if (isCurrent) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF111111), width: 1.4),
        ),
        padding: const EdgeInsets.all(2),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF111111),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.6),
          ),
          child: Center(
            child: Text(
              '$stepNumber',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: size * 0.42,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                height: 1,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Color(0xFFF0EDE7),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Container(
          width: size * 0.34,
          height: size * 0.34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF888888), width: 1.2),
          ),
        ),
      ),
    );
  }
}
