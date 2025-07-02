import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

// your existing mobile code here, WITHOUT dart:html
final _plug = FlutterLocalNotificationsPlugin();

class NotificationService {
  static Future<void> show({
    required String title,
    required String body,
  }) async {
    if (kIsWeb) return; // no-op on web
    const androidDetails = AndroidNotificationDetails(
      'alerts', 'Alerts',
      channelDescription: 'Sensor threshold alerts',
      importance: Importance.max,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    await _plug.show(0, title, body, 
      NotificationDetails(android: androidDetails, iOS: iosDetails),
    );
  }
}
