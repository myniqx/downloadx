import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'services/download_service.dart';
import 'ui/shell.dart';
import 'util/palette.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final service = DownloadService();
  await service.init();
  runApp(DlxApp(service: service));
}

class DlxApp extends StatelessWidget {
  final DownloadService service;
  const DlxApp({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'dlx',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: AppShell(service: service),
    );
  }
}
