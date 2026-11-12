// Deterministic expectations shared by the two processes of the T30 cold-start
// test. The app sandbox cannot read a host-written file, so the seed process
// writes a small test-only record into SharedPreferences and both processes
// agree on these fixed markers. Nothing here is product code.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Which half of the T30 process boundary this run is:
/// `seed`, `verify`, `autostart_off`, `crash` or `crash_verify`.
const kColdStartPhase = String.fromEnvironment('E2E_PHASE', defaultValue: 'seed');

/// Set by the wrapper for the auto-start-off phase (`on` otherwise).
const kColdStartAutoStart = String.fromEnvironment('E2E_AUTOSTART', defaultValue: 'on');

bool get coldStartAutoStartOff => kColdStartAutoStart == 'off';

/// The workspace file the real model creates through the `write` tool.
const kColdStartWorkspaceFile = 't30-cold-start.md';
const kColdStartWorkspaceMarker = 'T30-WORKSPACE-MARKER-7F3C';

/// Markers the real model must echo in its replies (short, one line each).
const kColdStartSeedReply = 'T30-SEED-REPLY-9A1';
const kColdStartVerifyReply = 'T30-VERIFY-REPLY-4B7';

/// The seed turn asks for the file and the reply marker; the tool instruction
/// is explicit so the turn exercises a real tool call, not only text.
const kColdStartSeedPrompt = 'T30 cold-start seed. Use the write tool to create the workspace file '
    '`$kColdStartWorkspaceFile` with exactly this one line: $kColdStartWorkspaceMarker\n'
    'After the tool succeeds, reply with exactly this one line: $kColdStartSeedReply\n'
    'Do not use bash, and do not create any other file.';

const kColdStartVerifyPrompt =
    'T30 cold-start verify. Reply with exactly this one line: $kColdStartVerifyReply';

/// An unsent composer draft: text and one small real PNG attachment.
const kColdStartDraftText = 'T30-COLD-START-DRAFT-3D8 这条草稿还没有发送';
const kColdStartDraftAttachment = 't30-draft.png';

/// The crash phase's deterministic local model and slow tool.
const kColdStartCrashProviderName = 'T30 Crash Mock';
const kColdStartCrashModel = 't30-crash-model';
const kColdStartCrashKey = 'sk-t30-crash-mock';
const kColdStartCrashPrompt = 'T30 crash turn: run the slow command.';
const kColdStartCrashCountFile = 't30-crash-count.txt';
const kColdStartCrashExecuted = 'T30-CRASH-EXECUTED';
const kColdStartCrashDone = 'T30-CRASH-DONE';
const kColdStartCrashCommand = 'echo $kColdStartCrashExecuted >> $kColdStartCrashCountFile; '
    'sleep 60; echo $kColdStartCrashDone >> $kColdStartCrashCountFile';

/// The foreground bash call needs a timeout longer than the kill window; the
/// tool's default may be shorter than the 60 s sleep.
const kColdStartCrashTimeoutMs = 120000;

/// Test-only SharedPreferences keys (named by task so they cannot collide).
const kColdStartSeedPrefs = 't30_cold_start_seed_v1';
const kColdStartCrashPrefs = 't30_cold_start_crash_v1';
const kColdStartDraftPrefs = 'chat_drafts_v1';
const kColdStartAutoStartPrefs = 'auto_start_local';

/// A 1x1 transparent PNG. Any file works; a real image also exercises the
/// draft tray's image path and byte-for-byte restoration.
final Uint8List kColdStartDraftPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// What the seed process records for the verify process.
@immutable
class ColdStartSeedRecord {
  const ColdStartSeedRecord({
    required this.sessionId,
    required this.title,
    required this.prompt,
    required this.replyMarker,
    required this.workspaceFile,
    required this.workspaceMarker,
    required this.workspacePath,
    required this.draftText,
    required this.attachmentName,
    required this.attachmentBytes,
    required this.createdAt,
  });

  final String sessionId;
  final String title;
  final String prompt;
  final String replyMarker;
  final String workspaceFile;
  final String workspaceMarker;

  /// Absolute path as the engine sees it (from `workspaceFiles/stat`).
  final String workspacePath;
  final String draftText;
  final String attachmentName;
  final int attachmentBytes;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'v': 1,
    'sessionId': sessionId,
    'title': title,
    'prompt': prompt,
    'replyMarker': replyMarker,
    'workspaceFile': workspaceFile,
    'workspaceMarker': workspaceMarker,
    'workspacePath': workspacePath,
    'draftText': draftText,
    'attachmentName': attachmentName,
    'attachmentBytes': attachmentBytes,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  static ColdStartSeedRecord? fromJson(Object? value) {
    if (value is! Map) return null;
    String string(String key) => value[key] is String ? value[key]! as String : '';
    final bytes = value['attachmentBytes'];
    final record = ColdStartSeedRecord(
      sessionId: string('sessionId'),
      title: string('title'),
      prompt: string('prompt'),
      replyMarker: string('replyMarker'),
      workspaceFile: string('workspaceFile'),
      workspaceMarker: string('workspaceMarker'),
      workspacePath: string('workspacePath'),
      draftText: string('draftText'),
      attachmentName: string('attachmentName'),
      attachmentBytes: bytes is int ? bytes : -1,
      createdAt: DateTime.tryParse(string('createdAt')) ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
    return record.sessionId.isEmpty ? null : record;
  }

  static ColdStartSeedRecord? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  String encode() => jsonEncode(toJson());
}

/// What the crash phase records before it is killed mid-turn.
@immutable
class ColdStartCrashRecord {
  const ColdStartCrashRecord({
    required this.sessionId,
    required this.providerId,
    required this.model,
    required this.countFile,
    required this.command,
    required this.prompt,
    this.baselineLines = 0,
  });

  final String sessionId;
  final String providerId;
  final String model;
  final String countFile;
  final String command;
  final String prompt;

  /// Lines present after the interrupted tool attempt (0 if it never ran):
  /// the no-re-execution baseline for the cold relaunch.
  final int baselineLines;

  Map<String, Object?> toJson() => {
    'v': 1,
    'sessionId': sessionId,
    'providerId': providerId,
    'model': model,
    'countFile': countFile,
    'command': command,
    'prompt': prompt,
    'baselineLines': baselineLines,
  };

  static ColdStartCrashRecord? fromJson(Object? value) {
    if (value is! Map) return null;
    String string(String key) => value[key] is String ? value[key]! as String : '';
    final baseline = value['baselineLines'];
    final record = ColdStartCrashRecord(
      sessionId: string('sessionId'),
      providerId: string('providerId'),
      model: string('model'),
      countFile: string('countFile'),
      command: string('command'),
      prompt: string('prompt'),
      baselineLines: baseline is int ? baseline : 0,
    );
    return record.sessionId.isEmpty ? null : record;
  }

  static ColdStartCrashRecord? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  String encode() => jsonEncode(toJson());
}

/// The workspace text as the engine's file API sees it, or null when missing.
String? crashCountLines(String? text) {
  if (text == null) return null;
  final lines = text
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  return lines.join('\n');
}

/// Test log lines; the host wrapper watches these.
void coldStartLog(String message) => debugPrint('[cold-start-e2e] $message');
