import 'package:flutter/material.dart';

/// A 24 px dotted-circle `+` — the "add" affordance beside a row of applied
/// tags.
class DottedAddButton extends StatelessWidget {
  const DottedAddButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: CustomPaint(
        painter: _DottedCirclePainter(),
        child: const SizedBox(
          width: 24,
          height: 24,
          child: Icon(Icons.add, size: 16, color: Color(0xFF9CA3AF)),
        ),
      ),
    );
  }
}

class _DottedCirclePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFD1D5DB)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final radius = size.width / 2 - 0.5;
    final center = size.center(Offset.zero);
    const dashCount = 16;
    const sweep = 3.1415926535 * 2 / dashCount;
    for (var i = 0; i < dashCount; i++) {
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius),
          i * sweep, sweep / 2, false, paint);
    }
  }

  @override
  bool shouldRepaint(_DottedCirclePainter oldDelegate) => false;
}
