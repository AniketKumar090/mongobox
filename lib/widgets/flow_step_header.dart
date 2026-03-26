import 'package:flutter/material.dart';

double flowHorizontalPadding(double width) {
  if (width >= 1100) return 40;
  if (width >= 700) return 28;
  return 20;
}

double flowContentMaxWidth(double width) {
  if (width >= 1100) return 920;
  if (width >= 700) return 780;
  return width;
}

class FlowStepHeader extends StatelessWidget {
  const FlowStepHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.steps,
    required this.currentStep,
    this.actions = const [],
    this.showBackButton = true,
  });

  final String title;
  final String subtitle;
  final List<String> steps;
  final int currentStep;
  final List<Widget> actions;
  final bool showBackButton;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tt = theme.textTheme;
    final safeStep = currentStep.clamp(1, steps.length);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        final canPop = Navigator.of(context).canPop();
        final actionWidgets =
            actions
                .map(
                  (action) => Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: action,
                  ),
                )
                .toList();

        return Container(
          padding: EdgeInsets.all(compact ? 16 : 20),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: cs.outline.withValues(alpha: 0.55)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showBackButton && canPop) ...[
                    _HeaderIconButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: 'Back',
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Step $safeStep of ${steps.length}',
                          style: tt.labelMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          title,
                          style: (compact ? tt.titleLarge : tt.headlineSmall)
                              ?.copyWith(
                                color: cs.onSurface,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: tt.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!compact && actionWidgets.isNotEmpty)
                    Wrap(children: actionWidgets),
                ],
              ),
              if (compact && actionWidgets.isNotEmpty) ...[
                const SizedBox(height: 14),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
              const SizedBox(height: 18),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: safeStep / steps.length,
                  minHeight: 8,
                  backgroundColor: cs.secondaryContainer,
                  valueColor: AlwaysStoppedAnimation<Color>(cs.secondary),
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: List.generate(steps.length, (index) {
                  final stepNumber = index + 1;
                  final isCurrent = stepNumber == safeStep;
                  final isComplete = stepNumber < safeStep;

                  final backgroundColor =
                      isCurrent
                          ? cs.primary
                          : isComplete
                          ? cs.secondaryContainer
                          : cs.tertiaryContainer;
                  final foregroundColor =
                      isCurrent ? cs.onPrimary : cs.onSurface;

                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: backgroundColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color:
                            isCurrent
                                ? cs.primary
                                : isComplete
                                ? cs.secondary.withValues(alpha: 0.35)
                                : cs.outline.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color:
                                isCurrent
                                    ? cs.onPrimary.withValues(alpha: 0.14)
                                    : isComplete
                                    ? cs.secondary
                                    : cs.surface,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child:
                              isComplete
                                  ? Icon(
                                    Icons.check_rounded,
                                    size: 14,
                                    color: cs.onSecondary,
                                  )
                                  : Text(
                                    '$stepNumber',
                                    style: tt.labelSmall?.copyWith(
                                      color:
                                          isCurrent
                                              ? cs.onPrimary
                                              : cs.onSurfaceVariant,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          steps[index],
                          style: tt.labelMedium?.copyWith(
                            color: foregroundColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, color: cs.onSurface),
          ),
        ),
      ),
    );
  }
}
