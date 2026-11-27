import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rear_eyes_desktop/agent_mcp.dart';
import 'package:rear_eyes_desktop/codex_status.dart';

void main() {
  test(
    'a completed Codex session briefly interrupts another active session',
    () {
      final home = Directory.systemTemp.createTempSync('robot-eyes-sessions');
      addTearDown(() => home.deleteSync(recursive: true));
      final now = DateTime.now();
      final month = now.month.toString().padLeft(2, '0');
      final day = now.day.toString().padLeft(2, '0');
      final sessions = Directory(
        '${home.path}/sessions/${now.year}/$month/$day',
      )..createSync(recursive: true);
      final completedAt = now.subtract(const Duration(seconds: 1));

      void writeTurn(String session, String event, DateTime at) {
        final line = jsonEncode({
          'timestamp': at.toIso8601String(),
          'type': 'event_msg',
          'payload': {'type': event},
        });
        File('${sessions.path}/rollout-$session.jsonl')
            .writeAsStringSync('$line\n');
      }

      writeTurn(
        'active',
        'turn_started',
        now.subtract(const Duration(minutes: 1)),
      );
      writeTurn('completed', 'turn_complete', completedAt);
      final codex = CodexStatus();
      final state = codex.read(codexHome: home.path)['state'] as String;
      expect(state, 'THINKING');
      expect(codex.lastCompletion, completedAt);

      String displayedAt(DateTime at) => AgentMcp.displayState(
        {state},
        fallback: 'IDLE',
        recentlyCompleted: codex.lastCompletion!.isAfter(
          at.subtract(AgentMcp.completionDuration),
        ),
      );

      expect(displayedAt(now), 'DONE');
      expect(
        displayedAt(completedAt.add(AgentMcp.completionDuration)),
        'THINKING',
      );
    },
  );

  test(
    'old Codex completion reports idle so the display can start its timer',
    () {
      final home = Directory.systemTemp.createTempSync('robot-eyes-idle');
      addTearDown(() => home.deleteSync(recursive: true));
      final at = DateTime.now().subtract(const Duration(minutes: 1));
      final month = at.month.toString().padLeft(2, '0');
      final day = at.day.toString().padLeft(2, '0');
      final sessions = Directory('${home.path}/sessions/${at.year}/$month/$day')
        ..createSync(recursive: true);
      final line = jsonEncode({
        'timestamp': at.toIso8601String(),
        'type': 'event_msg',
        'payload': {'type': 'turn_complete'},
      });
      File('${sessions.path}/rollout-completed.jsonl')
          .writeAsStringSync('$line\n');
      expect(CodexStatus().read(codexHome: home.path)['state'], 'IDLE');
    },
  );

  test('completion also interrupts work across AI tools', () {
    const states = {'THINKING', 'DONE'};
    expect(
      AgentMcp.displayState(states, fallback: 'IDLE', recentlyCompleted: true),
      'DONE',
    );
    expect(
      AgentMcp.displayState(states, fallback: 'IDLE', recentlyCompleted: false),
      'THINKING',
    );
    expect(
      AgentMcp.displayState(
        {...states, 'QUESTION'},
        fallback: 'IDLE',
        recentlyCompleted: true,
      ),
      'QUESTION',
    );
    expect(
      AgentMcp.displayState(
        {'DONE'},
        fallback: 'IDLE',
        recentlyCompleted: false,
      ),
      'DONE',
    );
  });
}
