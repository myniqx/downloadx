import 'package:flutter/material.dart';

import 'services/download_service.dart';
import 'ui/download_list_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4FC3F7),
          brightness: Brightness.dark,
        ),
      ),
      home: DownloadListScreen(service: service),
    );
  }
}
