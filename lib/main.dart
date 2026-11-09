import 'package:flutter/material.dart';

import 'studio.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CueApp());
}

class CueApp extends StatelessWidget {
  const CueApp({super.key});

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xff242620);
    return MaterialApp(
      title: 'Teleprompt by rocs',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff718464),
          primary: ink,
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: const Color(0xfff7f7f5),
        fontFamily: 'Arial',
      ),
      home: const Studio(),
    );
  }
}
