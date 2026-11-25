import 'dart:async';
import 'dart:io';

// Keep the SDK Material import for stable Flutter compatibility.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const desktopChannel = MethodChannel('com.reareyes/desktop');
const background = Color(0xff0e1219);
const surface = Color(0xff171e28);
const line = Color(0xff2a3544);
const ink = Color(0xffedf3f9);
const muted = Color(0xffa5b2c2);
const cyan = Color(0xff81e5d9);
const violet = Color(0xffc6b4ff);

Future<void> desktopAction(String method, [Object? arguments]) async {
  try {
    await desktopChannel.invokeMethod<void>(method, arguments);
  } on MissingPluginException {
    // The dashboard is also usable without a desktop host in widget tests.
  }
}

class DesktopTitleBar extends StatelessWidget {
  const DesktopTitleBar({super.key});

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: Color(0xff131922),
      border: Border(bottom: BorderSide(color: line)),
    ),
    child: SizedBox(
      height: Platform.isMacOS ? 36 : 46,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => unawaited(desktopAction('dragWindow')),
              onDoubleTap: () => unawaited(desktopAction('maximizeWindow')),
              child: Padding(
                padding: EdgeInsets.only(left: Platform.isMacOS ? 88 : 16),
                child: const Row(
                  children: [
                    Icon(Icons.remove_red_eye_outlined, color: cyan, size: 19),
                    SizedBox(width: 9),
                    Text(
                      'Robot Eyes',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (Platform.isWindows) ...[
            _button('最小化', Icons.remove, 'minimizeWindow'),
            _button('最大化或还原', Icons.crop_square_rounded, 'maximizeWindow'),
            _button('隐藏到托盘', Icons.close, 'hideWindow'),
          ],
        ],
      ),
    ),
  );

  static Widget _button(String label, IconData icon, String action) =>
      IconButton(
        tooltip: label,
        style: IconButton.styleFrom(
          shape: const RoundedRectangleBorder(),
          fixedSize: const Size(46, 44),
        ),
        onPressed: () => unawaited(desktopAction(action)),
        icon: Icon(icon, size: 17),
      );
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {this.active = false, super.key});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? cyan : muted;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return AnimatedContainer(
      duration: duration,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 6, color: color),
          const SizedBox(width: 7),
          AnimatedSwitcher(
            duration: duration,
            child: Text(
              label,
              key: ValueKey(label),
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
