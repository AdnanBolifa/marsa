import 'dart:async';

import 'files.dart';

class SyncOptions {
  const SyncOptions({
    this.exclude = const ['.git', 'node_modules', '.DS_Store'],
    this.delete = false,
    this.dryRun = false,
    this.maxFiles = 2000,
  });

  final List<String> exclude;
  final bool delete;
  final bool dryRun;
  final int maxFiles;
}

enum SyncOpKind { createDir, upload, update, deleteFile, deleteDir }

class SyncOp {
  const SyncOp({
    required this.kind,
    required this.relativePath,
    required this.srcPath,
    required this.dstPath,
    this.size = 0,
  });

  final SyncOpKind kind;
  final String relativePath;
  final String srcPath;
  final String dstPath;
  final int size;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'path': relativePath,
    'size': size,
  };
}

class SyncPlan {
  const SyncPlan({
    required this.srcRoot,
    required this.dstRoot,
    required this.ops,
    required this.newCount,
    required this.updateCount,
    required this.deleteCount,
    required this.totalBytes,
  });

  final String srcRoot;
  final String dstRoot;
  final List<SyncOp> ops;
  final int newCount;
  final int updateCount;
  final int deleteCount;
  final int totalBytes;

  bool get isEmpty => ops.isEmpty;

  Map<String, dynamic> toSummaryJson() => {
    'srcRoot': srcRoot,
    'dstRoot': dstRoot,
    'newFiles': newCount,
    'updatedFiles': updateCount,
    'deletedItems': deleteCount,
    'totalBytes': totalBytes,
    'operations': ops.map((o) => o.toJson()).toList(),
  };
}

class SyncResult {
  const SyncResult({
    required this.plan,
    required this.dryRun,
    required this.copiedCount,
    required this.deletedCount,
    required this.bytesTransferred,
  });

  final SyncPlan plan;
  final bool dryRun;
  final int copiedCount;
  final int deletedCount;
  final int bytesTransferred;

  Map<String, dynamic> toJson() => {
    'dryRun': dryRun,
    'copiedFiles': copiedCount,
    'deletedItems': deletedCount,
    'bytesTransferred': bytesTransferred,
    'plan': plan.toSummaryJson(),
  };
}

class _TreeEntry {
  _TreeEntry(this.relPath, this.fullPath, this.entry);
  final String relPath;
  final String fullPath;
  final FileEntry entry;
}

/// Plans an rsync-style directory sync from [src]/[srcRoot] to [dst]/[dstRoot].
Future<SyncPlan> planSync(
  FileBackend src,
  String srcRoot,
  FileBackend dst,
  String dstRoot, {
  SyncOptions options = const SyncOptions(),
}) async {
  final patterns = options.exclude
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();

  final srcTree = await _walk(src, srcRoot, patterns, options.maxFiles);
  Map<String, _TreeEntry> dstTree;
  try {
    dstTree = await _walk(dst, dstRoot, patterns, options.maxFiles);
  } catch (_) {
    dstTree = {};
  }

  final ops = <SyncOp>[];
  var newCount = 0;
  var updateCount = 0;
  var deleteCount = 0;
  var totalBytes = 0;

  // Ensure root destination exists if we have anything to copy.
  if (dstTree.isEmpty && srcTree.isNotEmpty) {
    ops.add(
      SyncOp(
        kind: SyncOpKind.createDir,
        relativePath: '',
        srcPath: srcRoot,
        dstPath: dstRoot,
      ),
    );
  }

  // Create missing directories first (sorted shallowest-first).
  final srcEntries = srcTree.values.toList()
    ..sort((a, b) => a.relPath.compareTo(b.relPath));

  for (final item in srcEntries) {
    final targetPath = _joinRel(dst, dstRoot, item.relPath);
    final existing = dstTree[item.relPath];
    if (item.entry.isDir) {
      if (existing == null || !existing.entry.isDir) {
        ops.add(
          SyncOp(
            kind: SyncOpKind.createDir,
            relativePath: item.relPath,
            srcPath: item.fullPath,
            dstPath: targetPath,
          ),
        );
      }
      continue;
    }

    if (existing == null) {
      newCount++;
      totalBytes += item.entry.size;
      ops.add(
        SyncOp(
          kind: SyncOpKind.upload,
          relativePath: item.relPath,
          srcPath: item.fullPath,
          dstPath: targetPath,
          size: item.entry.size,
        ),
      );
    } else if (_needsUpdate(item.entry, existing.entry)) {
      updateCount++;
      totalBytes += item.entry.size;
      ops.add(
        SyncOp(
          kind: SyncOpKind.update,
          relativePath: item.relPath,
          srcPath: item.fullPath,
          dstPath: targetPath,
          size: item.entry.size,
        ),
      );
    }
  }

  if (options.delete) {
    // Delete deepest paths first so directories are emptied before removal.
    final extras = dstTree.values
        .where((e) => !srcTree.containsKey(e.relPath))
        .toList()
      ..sort((a, b) => b.relPath.length.compareTo(a.relPath.length));
    for (final extra in extras) {
      deleteCount++;
      ops.add(
        SyncOp(
          kind: extra.entry.isDir ? SyncOpKind.deleteDir : SyncOpKind.deleteFile,
          relativePath: extra.relPath,
          srcPath: '',
          dstPath: extra.fullPath,
        ),
      );
    }
  }

  return SyncPlan(
    srcRoot: srcRoot,
    dstRoot: dstRoot,
    ops: ops,
    newCount: newCount,
    updateCount: updateCount,
    deleteCount: deleteCount,
    totalBytes: totalBytes,
  );
}

/// Executes a [SyncPlan] between [src] and [dst].
Future<SyncResult> executeSync(
  FileBackend src,
  FileBackend dst,
  SyncPlan plan, {
  void Function(int done, int total, String path)? onProgress,
}) async {
  var copied = 0;
  var deleted = 0;
  var bytes = 0;
  final total = plan.ops.length;

  for (var i = 0; i < total; i++) {
    final op = plan.ops[i];
    onProgress?.call(i, total, op.relativePath);
    switch (op.kind) {
      case SyncOpKind.createDir:
        try {
          await dst.mkdir(op.dstPath);
        } catch (_) {
          // Directory may already exist.
        }
      case SyncOpKind.upload:
      case SyncOpKind.update:
        await dst.write(op.dstPath, src.read(op.srcPath));
        copied++;
        bytes += op.size;
      case SyncOpKind.deleteFile:
        await dst.delete(op.dstPath, isDir: false);
        deleted++;
      case SyncOpKind.deleteDir:
        try {
          await dst.delete(op.dstPath, isDir: true);
          deleted++;
        } catch (_) {
          // Ignore if already removed by parent recursive delete.
        }
    }
  }
  onProgress?.call(total, total, '');

  return SyncResult(
    plan: plan,
    dryRun: false,
    copiedCount: copied,
    deletedCount: deleted,
    bytesTransferred: bytes,
  );
}

bool _needsUpdate(FileEntry src, FileEntry dst) {
  if (src.size != dst.size) return true;
  if (src.modified != null && dst.modified != null) {
    return src.modified!.difference(dst.modified!).inSeconds.abs() > 2;
  }
  return false;
}

String _joinRel(FileBackend backend, String root, String relPath) {
  var cur = root;
  for (final seg in relPath.split('/')) {
    if (seg.isEmpty) continue;
    cur = backend.join(cur, seg);
  }
  return cur;
}

Future<Map<String, _TreeEntry>> _walk(
  FileBackend backend,
  String root,
  List<String> exclude,
  int maxFiles,
) async {
  final out = <String, _TreeEntry>{};

  Future<void> visit(String dirPath, String relPrefix) async {
    final entries = await backend.list(dirPath);
    for (final e in entries) {
      if (out.length >= maxFiles) {
        throw StateError('Sync exceeded maxFiles limit ($maxFiles)');
      }
      final rel = relPrefix.isEmpty ? e.name : '$relPrefix/${e.name}';
      if (_isExcluded(e.name, rel, exclude)) continue;
      final full = backend.join(dirPath, e.name);
      out[rel] = _TreeEntry(rel, full, e);
      if (e.isDir) {
        await visit(full, rel);
      }
    }
  }

  await visit(root, '');
  return out;
}

bool _isExcluded(String name, String relPath, List<String> patterns) {
  for (final pat in patterns) {
    if (pat == name || pat == relPath) return true;
    final regex = _globToRegExp(pat);
    if (regex.hasMatch(name) || regex.hasMatch(relPath)) return true;
  }
  return false;
}

RegExp _globToRegExp(String glob) {
  final buf = StringBuffer('^');
  for (var i = 0; i < glob.length; i++) {
    final ch = glob[i];
    if (ch == '*') {
      buf.write('.*');
    } else if (ch == '?') {
      buf.write('.');
    } else if (r'\.+^$()[]{}|'.contains(ch)) {
      buf.write('\\$ch');
    } else {
      buf.write(ch);
    }
  }
  buf.write(r'$');
  return RegExp(buf.toString());
}
