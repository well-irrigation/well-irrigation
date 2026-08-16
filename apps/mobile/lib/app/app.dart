import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/config/app_config.dart';
import '../features/bootstrap/bootstrap_screen.dart';

class WellIrrigationApp extends StatelessWidget {
  const WellIrrigationApp({required this.config, super.key});

  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'إدارة البئر والسقي',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF1565C0),
      ),
      home: BootstrapScreen(config: config),
    );
  }
}

class ConfigurationFailureApp extends StatelessWidget {
  const ConfigurationFailureApp({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.settings_outlined, size: 48),
                  const SizedBox(height: 20),
                  const Text(
                    'إعداد التطبيق غير مكتمل',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    message,
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.ltr,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
