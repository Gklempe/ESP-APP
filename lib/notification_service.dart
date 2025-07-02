/// Public entry-point: picks the right implementation for the current platform.
export 'notification_service_mobile.dart'
    if (dart.library.html) 'notification_service_web.dart';
