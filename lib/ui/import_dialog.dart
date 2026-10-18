import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../theme.dart';

Future<void> showImportDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => const _ImportDialog(),
  );
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog();

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _urlController = TextEditingController();
  final _epgController = TextEditingController();
  bool _byFile = false;
  String? _localError;

  @override
  void dispose() {
    _urlController.dispose();
    _epgController.dispose();
    super.dispose();
  }

  Future<void> _importUrl(AppState app) async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    await app.importFromUrl(url);
    if (!mounted) return;
    if (app.lastError == null) {
      Navigator.of(context).pop();
      _toast('已导入 ${app.channels.length} 个频道');
    } else {
      setState(() => _localError = app.lastError);
    }
  }

  Future<void> _importFile(AppState app) async {
    setState(() => _localError = null);
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['m3u', 'm3u8', 'txt'],
      dialogTitle: '选择播放列表',
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (bytes.isEmpty) {
      setState(() => _localError = '无法读取该文件');
      return;
    }
    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      text = latin1.decode(bytes);
    }
    await app.importFromText(text, name: picked.name);
    if (!mounted) return;
    if (app.lastError == null) {
      Navigator.of(context).pop();
      _toast('已导入 ${app.channels.length} 个频道');
    } else {
      setState(() => _localError = app.lastError);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.stroke),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: SingleChildScrollView(
          child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.playlist_add_rounded, color: AppColors.accent),
                  const SizedBox(width: 10),
                  const Text(
                    '播放列表',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                app.hasContent
                    ? '当前：${app.playlist.name.isEmpty ? "未命名" : app.playlist.name} · ${app.channels.length} 个频道'
                    : '尚未导入播放列表',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
              ),
              const SizedBox(height: 18),
              _Segmented(
                byFile: _byFile,
                onChanged: (v) => setState(() {
                  _byFile = v;
                  _localError = null;
                }),
              ),
              const SizedBox(height: 16),
              if (!_byFile) ...[
                TextField(
                  controller: _urlController,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  style: const TextStyle(fontSize: 13.5),
                  onSubmitted: (_) => _importUrl(app),
                  decoration: const InputDecoration(
                    hintText: 'https://example.com/playlist.m3u',
                    prefixIcon: Icon(Icons.link_rounded, size: 18),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '支持 m3u / m3u8 订阅地址',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 11.5),
                ),
              ] else ...[
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _importFile(app),
                    icon: const Icon(Icons.folder_open_rounded, size: 18),
                    label: const Text('选择本地 .m3u / .m3u8 文件'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      side: const BorderSide(color: AppColors.stroke),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
              ],
              if (_localError != null) ...[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline_rounded, size: 15, color: AppColors.danger),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _localError!,
                        style: const TextStyle(color: AppColors.danger, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              const Divider(height: 1, color: AppColors.stroke),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Icon(Icons.event_note_rounded, size: 15, color: AppColors.textSecondary),
                  const SizedBox(width: 6),
                  const Text(
                    '节目单（XMLTV，可选）',
                    style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                  ),
                  const Spacer(),
                  if (app.epgUrl.isNotEmpty)
                    TextButton(
                      onPressed: () async {
                        await app.clearEpg();
                        if (context.mounted) setState(() {});
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.textSecondary,
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: const Text('清除', style: TextStyle(fontSize: 11.5)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _epgController,
                      style: const TextStyle(fontSize: 12.5),
                      decoration: InputDecoration(
                        hintText: app.epgUrl.isEmpty
                            ? 'https://example.com/epg.xml'
                            : (app.epgUrl.length > 46
                                ? '${app.epgUrl.substring(0, 46)}…'
                                : app.epgUrl),
                        isDense: true,
                        prefixIcon: const Icon(Icons.rss_feed_rounded, size: 16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: app.busy
                        ? null
                        : () async {
                            final u = _epgController.text.trim();
                            if (u.isEmpty) return;
                            await app.loadEpg(u);
                            if (!context.mounted) return;
                            if (app.lastError == null) {
                              _toast('节目单已载入，共 ${app.epg.length} 个频道');
                              setState(() {});
                            } else {
                              setState(() => _localError = app.lastError);
                            }
                          },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      side: const BorderSide(color: AppColors.stroke),
                      minimumSize: const Size(0, 42),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    child: const Text('载入', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (app.hasContent)
                    TextButton(
                      onPressed: () async {
                        await app.clearPlaylist();
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                      child: const Text('清空播放列表', style: TextStyle(fontSize: 12.5)),
                    ),
                  const Spacer(),
                  if (!_byFile)
                    FilledButton(
                      onPressed: app.busy ? null : () => _importUrl(app),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: AppColors.bg,
                      ),
                      child: app.busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.bg),
                            )
                          : const Text('导入'),
                    ),
                ],
              ),
              if (app.version.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '电视 v${app.version}',
                  style: const TextStyle(fontSize: 10.5, color: AppColors.textSecondary),
                ),
              ],
            ],
          ),
          ),
        ),
      ),
    );
  }
}

class _Segmented extends StatelessWidget {
  final bool byFile;
  final ValueChanged<bool> onChanged;

  const _Segmented({required this.byFile, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Row(
        children: [
          _seg('网络链接', Icons.link_rounded, !byFile, () => onChanged(false)),
          _seg('本地文件', Icons.folder_open_rounded, byFile, () => onChanged(true)),
        ],
      ),
    );
  }

  Widget _seg(String text, IconData icon, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? AppColors.surfaceAlt : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: active ? AppColors.accentDim : Colors.transparent),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: active ? AppColors.accent : AppColors.textSecondary),
              const SizedBox(width: 6),
              Text(
                text,
                style: TextStyle(
                  fontSize: 12.5,
                  color: active ? AppColors.textPrimary : AppColors.textSecondary,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
