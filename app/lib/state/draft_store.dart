import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'attachments.dart';

/// The folder unsent attachment bytes are kept in between launches: the app's
/// own support directory. Tests replace it with a temporary folder.
final draftAttachmentRootProvider = Provider<Future<Directory> Function()>((ref) {
  return () async => Directory('${(await getApplicationSupportDirectory()).path}/${DraftStore.attachmentsFolder}');
});

/// What is in the composer of one conversation and not sent yet.
class ChatDraft {
  const ChatDraft({this.text = '', this.attachments = const [], required this.updatedAt});

  final String text;
  final List<DraftAttachment> attachments;
  final DateTime updatedAt;
}

class DraftState {
  const DraftState({this.drafts = const {}, this.loaded = false});

  /// By session id; `new` is the new-chat screen.
  final Map<String, ChatDraft> drafts;

  /// The saved texts are in (they arrive a moment after launch).
  final bool loaded;
}

/// Composer drafts per conversation. The latest 30 texts and the bytes of
/// their un-sent attachments survive a restart: attachments are copied into
/// the app's own support folder and read back on the next launch. A build
/// without that folder (some tests, a platform without `path_provider`) keeps
/// the text and drops the attachments.
class DraftStore extends Notifier<DraftState> {
  static const preferenceKey = 'chat_drafts_v1';
  static const limit = 30;

  /// Folder under the app support directory that holds the attachment bytes.
  static const attachmentsFolder = 'draft-attachments';

  Timer? _write;
  final _forgotten = <String>{};
  late Future<void> _restored;

  /// One save at a time: a timer's write and the next save must not interleave
  /// (an older snapshot could otherwise put back a draft that was just sent).
  Future<void> _flushing = Future<void>.value();

  /// Resolved once: the app support folder, or null where there is none. The
  /// future (not only its value) is kept, so a second save waits for the first
  /// lookup instead of seeing "not ready" and dropping the bytes.
  Future<Directory?>? _attachments;

  /// File name each restored attachment came from, so saving it again does not
  /// copy the bytes a second time.
  final _storedNames = <int, String>{};

  @override
  DraftState build() {
    ref.onDispose(() => _write?.cancel());
    _restored = _restore();
    return const DraftState();
  }

  Future<Directory?> _attachmentRoot() => _attachments ??= _resolveAttachments();

  Future<Directory?> _resolveAttachments() async {
    try {
      return await (await ref.read(draftAttachmentRootProvider)()).create(recursive: true);
    } catch (_) {
      // No path_provider channel (tests) or no writable folder: text only.
      return null;
    }
  }

  /// The folder of one draft; conversation ids are opaque, so escape them.
  static String _folderName(String key) => Uri.encodeComponent(key);

  /// A safe file name that keeps the visible name's tail (extensions).
  static String _fileName(DraftAttachment a, int index) {
    final safe = a.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    final tail = safe.length <= 80 ? safe : safe.substring(safe.length - 80);
    return '${a.id}-$index-$tail';
  }

  Future<DraftAttachment?> _readAttachment(Directory? root, String key, Map<Object?, Object?> stored) async {
    final file = stored['f'];
    final name = stored['n'];
    if (root == null || file is! String || file.isEmpty || name is! String) return null;
    // Metadata is app-private, but never let a hand-edited value walk outside.
    if (file.contains('/') || file.contains(r'\') || file == '.' || file == '..') return null;
    try {
      final bytes = await File('${root.path}/${_folderName(key)}/$file').readAsBytes();
      if (bytes.isEmpty) return null;
      final media = stored['m'];
      final attachment = DraftAttachment(
        name: name,
        bytes: bytes,
        mediaType: media is String && media.isNotEmpty ? media : null,
      );
      _storedNames[attachment.id] = file;
      return attachment;
    } catch (_) {
      // The copy is gone or unreadable: the rest of the draft still loads.
      return null;
    }
  }

  Future<Map<String, ChatDraft>> _readSaved() async {
    final restored = <String, ChatDraft>{};
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(preferenceKey);
    if (raw == null) return restored;
    for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map).entries) {
      if (key is! String || value is! Map) continue;
      final text = value['t'];
      final at = value['at'];
      final attachments = <DraftAttachment>[];
      final stored = value['a'];
      if (stored is List && stored.isNotEmpty) {
        final root = await _attachmentRoot();
        for (final item in stored) {
          if (item is! Map) continue;
          final attachment = await _readAttachment(root, key, item.cast<Object?, Object?>());
          if (attachment != null) attachments.add(attachment);
        }
      }
      restored[key] = ChatDraft(
        text: text is String ? text : '',
        attachments: List.unmodifiable(attachments),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(at is int ? at : 0),
      );
    }
    return restored;
  }

  Future<void> _restore() async {
    var restored = <String, ChatDraft>{};
    try {
      restored = await _readSaved();
    } catch (_) {
      // No preferences backend (tests) or an unreadable value: start empty.
    }
    if (!ref.mounted) return;
    // Anything typed before the load finished wins.
    state = DraftState(
      drafts: _latest({...restored, ...state.drafts}..removeWhere((key, _) => _forgotten.contains(key))),
      loaded: true,
    );
  }

  Map<String, ChatDraft> _latest(Map<String, ChatDraft> drafts) {
    final entries = drafts.entries.toList()..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
    return Map.unmodifiable(Map.fromEntries(entries.take(limit)));
  }

  /// Empty text and no attachments drops the slot.
  void save(String key, String text, List<DraftAttachment> attachments) {
    if (_forgotten.contains(key)) return;
    final current = state.drafts[key];
    if ((current?.text ?? '') == text && listEquals(current?.attachments ?? const [], attachments)) {
      return;
    }
    final next = {...state.drafts};
    if (text.isEmpty && attachments.isEmpty) {
      next.remove(key);
    } else {
      next[key] = ChatDraft(text: text, attachments: List.unmodifiable(attachments), updatedAt: DateTime.now());
    }
    state = DraftState(drafts: _latest(next), loaded: state.loaded);
    _write?.cancel();
    _write = Timer(const Duration(milliseconds: 400), () => unawaited(flush()));
  }

  void clear(String key) => save(key, '', const []);

  /// A deleted session cannot regain a draft through a late preferences load
  /// or the outgoing chat screen's save-on-selection/dispose callback.
  void forget(String key) {
    _forgotten.add(key);
    state = DraftState(drafts: Map.unmodifiable({...state.drafts}..remove(key)), loaded: state.loaded);
    _write?.cancel();
    _write = Timer(const Duration(milliseconds: 400), () => unawaited(flush()));
  }

  /// Writes the texts and attachment bytes now (also done 400 ms after the
  /// last change). Saves run one after another.
  Future<void> flush() {
    final next = _flushing.then((_) => _flush());
    _flushing = next.catchError((Object _) {});
    return next;
  }

  Future<void> _flush() async {
    _write?.cancel();
    _write = null;
    // Writing before the saved drafts are in would drop them.
    await _restored;
    if (!ref.mounted) return;
    final drafts = state.drafts;
    final savedAttachments = <String, List<Map<String, Object?>>>{};
    // Resolve the folder even when no draft has attachments: the previous
    // launch may have left bytes behind, and clearing the last attachment
    // must delete them instead of leaving them in the sandbox.
    final root = await _attachmentRoot();
    if (root != null) {
      final keep = <String>{
        for (final MapEntry(:key, :value) in drafts.entries)
          if (value.attachments.isNotEmpty) _folderName(key),
      };
      for (final MapEntry(:key, :value) in drafts.entries) {
        if (value.attachments.isEmpty) continue;
        final dir = Directory('${root.path}/${_folderName(key)}');
        try {
          await dir.create(recursive: true);
          final files = <Map<String, Object?>>[];
          for (final (index, attachment) in value.attachments.indexed) {
            final stored = _storedNames[attachment.id];
            final file = stored != null && stored.length <= 160 ? stored : _fileName(attachment, index);
            final target = File('${dir.path}/$file');
            if (!await target.exists() || await target.length() != attachment.size) {
              await target.writeAsBytes(attachment.bytes, flush: true);
            }
            _storedNames[attachment.id] = file;
            files.add({'n': attachment.name, 'm': attachment.mediaType, 'f': file});
          }
          savedAttachments[key] = files;
          // A removed attachment should not keep occupying the phone.
          final names = {for (final file in files) file['f']};
          await for (final entity in dir.list()) {
            if (entity is! File || names.contains(entity.path.split(Platform.pathSeparator).last)) continue;
            try {
              await entity.delete();
            } catch (_) {}
          }
        } catch (_) {
          // The text still goes; an unwritable attachment copy is dropped.
        }
      }
      // Drafts that were sent or cleared have no folder left behind.
      try {
        await for (final entity in root.list()) {
          // Directory URIs end in a slash; the path is the reliable name.
          if (entity is! Directory || keep.contains(entity.path.split(Platform.pathSeparator).last)) continue;
          await entity.delete(recursive: true);
        }
      } catch (_) {}
      if (keep.isEmpty) {
        // The folder only exists for un-sent attachments; drop it once empty.
        try {
          await root.delete(recursive: true);
        } catch (_) {}
      }
    }
    final alive = {for (final draft in drafts.values) for (final attachment in draft.attachments) attachment.id};
    _storedNames.removeWhere((id, _) => !alive.contains(id));

    final json = <String, Object?>{};
    for (final MapEntry(:key, :value) in drafts.entries) {
      final files = savedAttachments[key];
      if (value.text.isEmpty && (files == null || files.isEmpty)) continue;
      json[key] = {
        't': value.text,
        'at': value.updatedAt.millisecondsSinceEpoch,
        if (files != null && files.isNotEmpty) 'a': files,
      };
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(preferenceKey, jsonEncode(json));
    } catch (_) {}
  }
}

final draftStoreProvider = NotifierProvider<DraftStore, DraftState>(DraftStore.new);
