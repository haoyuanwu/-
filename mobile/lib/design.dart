// Keep the Flutter SDK Material import for compatibility with stable Flutter.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

const backdrop = Color(0xff070c14);
const panelColor = Color(0xff101b29);
const borderColor = Color(0xff30445c);
const primaryInk = Color(0xffe9f6ff);
const secondaryInk = Color(0xffa7bbd0);
const cyan = Color(0xff77e8f4);
const violet = Color(0xffbdabfc);

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Row(
      children: [
        Container(
          width: 3,
          height: 13,
          decoration: BoxDecoration(
            color: cyan,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}
