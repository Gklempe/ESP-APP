import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'package:fl_chart/fl_chart.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_map/flutter_map.dart' as flutter_map;
import 'package:latlong2/latlong.dart' as latlong2;
import 'package:syncfusion_flutter_gauges/gauges.dart';
import 'package:flutter/scheduler.dart';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as fln;
import 'dart:html' as html;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_web_bluetooth/flutter_web_bluetooth.dart';




final _notifications = fln.FlutterLocalNotificationsPlugin();

extension LatLngGoogle on latlong2.LatLng {
  gmaps.LatLng toGoogle() => gmaps.LatLng(latitude, longitude);
}

Future<void> main() async {
  // ensure binding before any async work
  WidgetsFlutterBinding.ensureInitialized();

  // 1️⃣ Android init settings
  const androidInit = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
  // 2️⃣ iOS init settings
  const iosInit = fln.DarwinInitializationSettings();
  // 3️⃣ Initialize & await
  await _notifications.initialize(
    const fln.InitializationSettings(android: androidInit, iOS: iosInit),
  );

  runApp(MyApp());
}

class NotificationService {
  static final _plug = fln.FlutterLocalNotificationsPlugin();

  static Future<void> show({
    required String title,
    required String body,
  }) async {
    // 1) Web: use HTML5 API
    if (kIsWeb) {
      // request permission if needed
      if (html.Notification.permission == 'granted') {
        html.Notification(title, body: body);
      } else {
        final perm = await html.Notification.requestPermission();
        if (perm == 'granted') {
          html.Notification(title, body: body);
        } else {
          debugPrint('🔕 notification permission denied');
        }
      }
      return;
    }

    // 2) Mobile/Desktop: use flutter_local_notifications
    const androidDetails = fln.AndroidNotificationDetails(
      'alerts',
      'Alerts',
      channelDescription: 'Sensor threshold alerts',
      importance: fln.Importance.max,
      priority: fln.Priority.high,
    );
    const iosDetails = fln.DarwinNotificationDetails();
    await _plug.show(
      0,
      title,
      body,
      fln.NotificationDetails(android: androidDetails, iOS: iosDetails),
    );
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with TickerProviderStateMixin {
  late final MyAppState appState;

  @override
  void initState() {
    super.initState();
    appState = MyAppState();
    appState.startFakeDataTicker(this);
  }

  @override
  void dispose() {
    appState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: appState,
      child: MaterialApp(
        title: 'Smart Car Monitor',
        theme: ThemeData.dark().copyWith(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
        ),
        home: MyHomePage(),
      ),
    );
  }
}



class RoutePoint {
  final latlong2.LatLng pos;
  final DateTime time;
  RoutePoint(this.pos, this.time);
}

class MyAppState extends ChangeNotifier {
  double battery = 12.5;
  String ignition = "ON";
  String headlight = "OFF";
  double cabinTemp = 24.3;
  double engineTemp = 70.0;
  String doorStatus = "Closed";
  double latitude = 37.9838;
  double longitude = 23.7275;
  double gpsSpeed = 0.0;
  double rpm = 0.0;
  //List<gmaps.LatLng> route = [];

  double highTempThreshold = 80.0;
  double lowBatteryThreshold = 80.0;
  double overSpeedThreshold = 80.0;

  bool _hasAlertedHighTemp = false;
  bool _hasAlertedLowBattery = false;
  bool _hasAlertedOverSpeed = false;

  List<double> engineTempHistory = List.filled(20, 70.0);
  List<double> batteryHistory = List.filled(20, 12.5);
  List<double> cabinTempHistory = List.filled(20, 24.3);

  //final Random _random = Random();
  late Ticker _ticker;

  DateTime? tripStart;
  DateTime? tripEnd;
  List<latlong2.LatLng> route = [];
  final List<DateTime> _ts = [];
  List<latlong2.LatLng> stops  = [];
  final List<double> _speedLog = [];

  static const _stopDur = Duration(minutes: 3);
  static const _radiusM = 10;

  final _geo = latlong2.Distance();


  void _appendPoint(latlong2.LatLng p) {
    final now = DateTime.now();
    route.add(p);
    _ts.add(now);

    if (route.length < 2) return;

    final dist = _geo(route[route.length - 2], p);
    if (dist < _radiusM) {
      final firstIdx = _ts.lastIndexWhere(
        (t) => _geo(route[_ts.indexOf(t)], p) > _radiusM,
      );
      final since = firstIdx == -1
          ? now.difference(_ts.first)
          : now.difference(_ts[firstIdx + 1]);

      if (since >= _stopDur &&
          (stops.isEmpty || _geo(stops.last, p) > _radiusM)) {
        stops.add(p);
      }
    }
  } 

  double get totalDistance {
    if (route.length < 2) return 0.0;
    final dist = latlong2.Distance();
    double sum = 0;
    for (var i = 1; i < route.length; i++) {
      final prev = route[i - 1];
      final curr = route[i];
      sum += dist(
        latlong2.LatLng(prev.latitude, prev.longitude),
        latlong2.LatLng(curr.latitude, curr.longitude),
      );
    }
    return sum;
  }

  double get maxSpeed => _speedLog.isEmpty ? 0 : _speedLog.reduce(max);
  double get avgSpeed => _speedLog.isEmpty
      ? 0
      : _speedLog.reduce((a, b) => a + b) / _speedLog.length;
  Duration get duration => (tripStart == null || tripEnd == null)
      ? Duration.zero
      : tripEnd!.difference(tripStart!);

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    highTempThreshold =
        prefs.getDouble('highTempThreshold') ?? highTempThreshold;
    lowBatteryThreshold =
        prefs.getDouble('lowBatteryThreshold') ?? lowBatteryThreshold;
    overSpeedThreshold =
        prefs.getDouble('overSpeedThreshold') ?? overSpeedThreshold;
    notifyListeners();
  }

  void simulateRouteToAthens({
    int count = 5,
    double lateralJitter = 0.02, // in degrees (~2 km)
  }) {
    final start = latlong2.LatLng(latitude, longitude);
    const end = latlong2.LatLng(37.9838, 23.7275);
    final rnd = Random();

    // 1) pick `count` random t in (0…1), build point on straight line + jitter
    final mids = List<latlong2.LatLng>.generate(count, (_) {
      final t = rnd.nextDouble();
      final baseLat = start.latitude  + (end.latitude  - start.latitude ) * t;
      final baseLon = start.longitude + (end.longitude - start.longitude) * t;
      // add small random offset perpendicular-ish
      final dx = (rnd.nextDouble() - 0.5) * lateralJitter;
      final dy = (rnd.nextDouble() - 0.5) * lateralJitter;
      return latlong2.LatLng(baseLat + dx, baseLon + dy);
    });

    // 2) build full route: start → random mids → end
    route = [start, ...mids, end];

    // 3) place “stop” markers at those mids
    stops = List.from(mids);

    notifyListeners();
  }

  void startTrip() {
    route.clear();
    _speedLog.clear();
    tripStart = DateTime.now();
    tripEnd = null;
    notifyListeners();
  }

  void onNewPosition(double lat, double lng, double speedKmh) {
    route.add(latlong2.LatLng(lat, lng));
    _speedLog.add(speedKmh);
    notifyListeners();
  }

  void startFakeDataTicker(TickerProvider vsync) {
    _ticker = vsync.createTicker((_) => refreshFakeData())..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  MyAppState() {
    _initLocation();

    _loadSettings();
  }

  

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('highTempThreshold', highTempThreshold);
    await prefs.setDouble('lowBatteryThreshold', lowBatteryThreshold);
    await prefs.setDouble('overSpeedThreshold', overSpeedThreshold);
  }

  Future<void> _initLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    if (permission == LocationPermission.deniedForever) return;

    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((pos) {
      latitude = pos.latitude;
      longitude = pos.longitude;
      gpsSpeed = pos.speed * 3.6;
      _appendPoint(latlong2.LatLng(latitude, longitude));
      notifyListeners();
    });
  }

  void refreshFakeData() {
    final t = DateTime.now().second + DateTime.now().millisecond / 1000;

    battery = 12.5 + (Random().nextDouble() - 0.5) * 0.3;
    ignition = "ON";
    headlight = (DateTime.now().second % 10 < 5) ? "ON" : "OFF";
    cabinTemp = 22 + 3 * sin(t / 5) + (Random().nextDouble() - 0.5); // ~22–25°C
    engineTemp =
        70 + 10 * sin(t / 8) + (Random().nextDouble() - 0.5); // ~70–80°C
    doorStatus = (DateTime.now().second % 8 == 0) ? "Open" : "Closed";
    gpsSpeed = 60 + 30 * sin(t / 3); // ~30–90 km/h
    double gearBasedRpm;
    if (gpsSpeed < 20) {
      gearBasedRpm = gpsSpeed * 120;
    } else if (gpsSpeed < 40) {
      gearBasedRpm = gpsSpeed * 90;
    } else if (gpsSpeed < 70) {
      gearBasedRpm = gpsSpeed * 70;
    } else if (gpsSpeed < 110) {
      gearBasedRpm = gpsSpeed * 60;
    } else {
      gearBasedRpm = gpsSpeed * 50;
    }
    rpm = max(gearBasedRpm, 0); // Clamp to 0+

    _updateHistory(engineTempHistory, engineTemp);
    _updateHistory(batteryHistory, battery);
    _updateHistory(cabinTempHistory, cabinTemp);

    // 1) High Temp
    if (engineTemp >= highTempThreshold && !_hasAlertedHighTemp) {
      NotificationService.show(
        title: 'High Engine Temp',
        body: 'Engine temp is ${engineTemp.toStringAsFixed(1)}°C',
      );
      _hasAlertedHighTemp = true;
    } else if (engineTemp < highTempThreshold) {
      _hasAlertedHighTemp = false;
    }

    // 2) Low Battery
    if (battery <= lowBatteryThreshold && !_hasAlertedLowBattery) {
      NotificationService.show(
        title: 'Low Battery',
        body: 'Battery voltage is ${battery.toStringAsFixed(2)}V',
      );
      _hasAlertedLowBattery = true;
    } else if (battery > lowBatteryThreshold) {
      _hasAlertedLowBattery = false;
    }

    // 3) Over Speed
    if (gpsSpeed >= overSpeedThreshold && !_hasAlertedOverSpeed) {
      NotificationService.show(
        title: 'Overspeed Warning',
        body: 'Speed is ${gpsSpeed.toStringAsFixed(1)} km/h',
      );
      _hasAlertedOverSpeed = true;
    } else if (gpsSpeed < overSpeedThreshold) {
      _hasAlertedOverSpeed = false;
    }

    notifyListeners();
  }

  void _updateHistory(List<double> list, double newValue) {
    final newList = List<double>.from(list)
      ..removeAt(0)
      ..add(newValue);

    if (identical(list, engineTempHistory)) {
      engineTempHistory = newList;
    } else if (identical(list, batteryHistory)) {
      batteryHistory = newList;
    } else if (identical(list, cabinTempHistory)) {
      cabinTempHistory = newList;
    }
  }
}

class BluetoothScreen extends StatefulWidget {
  const BluetoothScreen({Key? key}) : super(key: key);

  @override
  State<BluetoothScreen> createState() => _BluetoothScreenState();
}

class _BluetoothScreenState extends State<BluetoothScreen> {
  // Mobile-only subscriptions:
  StreamSubscription<BluetoothAdapterState>? _stateSub;
  StreamSubscription<List<ScanResult>>?     _resultsSub;
  final List<ScanResult> _results = [];
  bool _scanning = false;

  @override
  void initState() {
    super.initState();

    if (!kIsWeb) {
      // Mobile: watch adapter state
      _stateSub = FlutterBluePlus.adapterState.listen((state) {
        if (state == BluetoothAdapterState.off && mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content:
                    Text('Bluetooth is OFF – please turn it on in settings'),
              ),
            );
          });
        }
      });
      // Start initial scan on Mobile
      _startScan();
    }
  }

  Future<void> _startScan() async {
    if (kIsWeb) {
      final webBluetooth = FlutterWebBluetooth.instance;

      // 1) check support
      final supported = await webBluetooth.isBluetoothApiSupported;
      if (!supported) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Web Bluetooth not supported')),
        );
        return;
      }

      // 2) build an "accept all devices" request
      final options = RequestOptionsBuilder.acceptAllDevices();

      // 3) fire it and handle result or cancellation
      try {
        final device = await FlutterWebBluetooth.instance.requestDevice(
          options,
        );
        final rawName = device.name;
        final displayName = (rawName != null && rawName.isNotEmpty)
          ? rawName
          : device.id;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Selected device: $displayName')),
        );
      } catch (e) {
        // user canceled or some other error
        debugPrint('Web Bluetooth picker failed: $e');
      }
      return;
    }

    // ─── Mobile: your existing flutter_blue_plus scan logic ──

    // 1️⃣ Ensure Bluetooth is ON
    final state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on) {
      await FlutterBluePlus.turnOn();
      await FlutterBluePlus.adapterState
          .firstWhere((s) => s == BluetoothAdapterState.on);
    }

    // 2️⃣ Clear old results & listen to new ones
    setState(() {
      _results.clear();
      _scanning = true;
    });
    _resultsSub?.cancel();
    _resultsSub = FlutterBluePlus.scanResults.listen((allResults) {
      setState(() {
        _results
          ..clear()
          ..addAll(allResults);
      });
    });

    // 3️⃣ Start & auto-stop scan after 5s
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    Future.delayed(const Duration(seconds: 5), () {
      FlutterBluePlus.stopScan();
      setState(() => _scanning = false);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _resultsSub?.cancel();
    if (!kIsWeb) FlutterBluePlus.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // On Web, we just show a prompt; on Mobile, show scan results.
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bluetooth Devices'),
        actions: [
          IconButton(
            icon: Icon(_scanning ? Icons.stop : Icons.refresh),
            onPressed: _scanning ? null : _startScan,
          ),
        ],
      ),
      body: kIsWeb
          ? Center(
              child: Text(
                'Tap the refresh button to open the Bluetooth device chooser.',
                textAlign: TextAlign.center,
              ),
            )
          : _scanning && _results.isEmpty
              ? const Center(child: Text('Scanning for devices…'))
              : ListView.builder(
                  itemCount: _results.length,
                  itemBuilder: (_, i) {
                    final r      = _results[i];
                    final idStr  = r.device.remoteId.toString();
                    final nameObj = r.device.platformName;
                    final name   = (nameObj.isNotEmpty)
                        ? nameObj
                        : idStr;
                    return ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(name),
                      subtitle: Text(idStr),
                      trailing: Text('${r.rssi} dBm'),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _scanning
            ? () {
                if (!kIsWeb) FlutterBluePlus.stopScan();
                setState(() => _scanning = false);
              }
            : _startScan,
        child:
            Icon(_scanning ? Icons.bluetooth_disabled : Icons.bluetooth_searching),
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();

    _timer = Timer.periodic(Duration(seconds: 2), (_) {
      final appState = context.read<MyAppState>();
      appState.refreshFakeData();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _buildSensorCard(IconData icon, String label, String value) {
    return Card(
      elevation: 4,
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Icon(icon, size: 30, color: Colors.deepOrange),
        title: Text(
          label,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(value, style: TextStyle(fontSize: 18)),
      ),
    );
  }

  Widget buildSpeedRpmGauges(double speed, double rpm) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Speed Gauge
        Expanded(
          child: SfRadialGauge(
            title: GaugeTitle(
              text: 'Speed (km/h)',
              textStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            axes: [
              RadialAxis(
                minimum: 0,
                maximum: 240,
                showTicks: true,
                showLabels: true,
                interval: 20,
                axisLabelStyle: GaugeTextStyle(
                  color: Colors.white,
                  fontSize: 12,
                ),
                majorTickStyle: MajorTickStyle(
                  color: Colors.white,
                  length: 8,
                  thickness: 2,
                ),
                minorTicksPerInterval: 0,
                axisLineStyle: AxisLineStyle(
                  thickness: 0.1,
                  thicknessUnit: GaugeSizeUnit.factor,
                ),

                ranges: [
                  GaugeRange(startValue: 0, endValue: 100, color: Colors.green),
                  GaugeRange(
                    startValue: 100,
                    endValue: 180,
                    color: Colors.orange,
                  ),
                  GaugeRange(startValue: 180, endValue: 240, color: Colors.red),
                ],

                pointers: [
                  NeedlePointer(
                    value: speed,
                    enableAnimation: true,
                    animationDuration: 800,

                    needleLength: 0.8,
                    needleStartWidth: 0,
                    needleEndWidth: 5,

                      tailStyle: TailStyle(
                      length: 0, // no backwards length
                      width: 0, // no backwards width
                      color: Colors.transparent, // fully transparent
                    ),

                    knobStyle: KnobStyle(
                      knobRadius: 0.04,
                      color: Colors.deepOrange,
                    ),
                  ),
                ],

                annotations: [
                  GaugeAnnotation(
                    angle: 90,
                    positionFactor: 0.75,
                    widget: Text(
                      '${speed.toStringAsFixed(1)} km/h',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(width: 16),

        // RPM Gauge
        Expanded(
          child: SfRadialGauge(
            title: GaugeTitle(
              text: 'RPM',
              textStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            axes: [
              RadialAxis(
                minimum: 0,
                maximum: 8000,
                showTicks: true,
                showLabels: true,
                interval: 1000,
                axisLabelStyle: GaugeTextStyle(
                  color: Colors.white,
                  fontSize: 12,
                ),
                majorTickStyle: MajorTickStyle(
                  color: Colors.white,
                  length: 8,
                  thickness: 2,
                ),
                minorTicksPerInterval: 0,
                axisLineStyle: AxisLineStyle(
                  thickness: 0.1,
                  thicknessUnit: GaugeSizeUnit.factor,
                ),

                ranges: [
                  GaugeRange(
                    startValue: 0,
                    endValue: 3000,
                    color: Colors.green,
                  ),
                  GaugeRange(
                    startValue: 3000,
                    endValue: 6000,
                    color: Colors.orange,
                  ),
                  GaugeRange(
                    startValue: 6000,
                    endValue: 8000,
                    color: Colors.red,
                  ),
                ],

                pointers: [
                  NeedlePointer(
                    value: rpm,
                    enableAnimation: true,
                    animationDuration: 800,

                    needleLength: 0.8,
                    needleStartWidth: 0,
                    needleEndWidth: 5,

                      tailStyle: TailStyle(
                      length: 0, // no backwards length
                      width: 0, // no backwards width
                      color: Colors.transparent, // fully transparent
                    ),

                    knobStyle: KnobStyle(
                      knobRadius: 0.04,
                      color: Colors.deepOrange,
                    ),
                  ),
                ],

                annotations: [
                  GaugeAnnotation(
                    angle: 90,
                    positionFactor: 0.75,
                    widget: Text(
                      '${rpm.toStringAsFixed(0)} RPM',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }


  Widget _buildTempChart(
    List<double> history, {
    Color color = Colors.deepOrange,
  }) {
    final minY = history.reduce((a, b) => a < b ? a : b) - 1;
    final maxY = history.reduce((a, b) => a > b ? a : b) + 1;

    return LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        lineTouchData: LineTouchData(
          enabled: true,
          handleBuiltInTouches: true,
          touchTooltipData: LineTouchTooltipData(
            tooltipBorderRadius: BorderRadius.circular(8),
            tooltipPadding: const EdgeInsets.all(8),
            getTooltipColor: (_) => Colors.black54,
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                return LineTooltipItem(
                  '${spot.y}',
                  const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                );
              }).toList();
            },
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) => Text(
                value.toStringAsFixed(0),
                style: TextStyle(fontSize: 10, color: Colors.white70),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 5,
              getTitlesWidget: (value, meta) => Text(
                '${value.toInt()}s',
                style: TextStyle(fontSize: 10, color: Colors.white70),
              ),
            ),
          ),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: FlGridData(show: true),
        borderData: FlBorderData(show: true),
        lineBarsData: [
          LineChartBarData(
            spots: history
                .asMap()
                .entries
                .map((e) => FlSpot(e.key.toDouble(), e.value))
                .toList(),
            isCurved: true,
            color: color,
            barWidth: 3,
            dotData: FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: color.withAlpha((0.3 * 0xFF).round()),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<MyAppState>();
    //bool followLocation = true;
    return Scaffold(
      appBar: AppBar(
        title: Text('Smart Car Monitor'),
        actions: [
          IconButton(
            icon: Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => SettingsScreen()),
            ),
          ),
          IconButton(
            icon: Icon(Icons.bluetooth_searching),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => BluetoothScreen()),
            ),
          ),
          IconButton(
            icon: Icon(Icons.alt_route),
            tooltip: 'Simulate Route to Athens',
            onPressed: () {
              context.read<MyAppState>().simulateRouteToAthens();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Route (+5 random points) simulated!')),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        child: Icon(Icons.map),
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => MapScreen()),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _buildSensorCard(
              Icons.battery_full,
              "Battery Voltage",
              "${appState.battery.toStringAsFixed(2)} V",
            ),
            _buildSensorCard(
              Icons.thermostat,
              "Cabin Temp",
              "${appState.cabinTemp.toStringAsFixed(1)} °C",
            ),
            _buildSensorCard(
              Icons.local_fire_department,
              "Engine Temp",
              "${appState.engineTemp.toStringAsFixed(1)} °C",
            ),
            _buildSensorCard(
              Icons.door_front_door,
              "Door Status",
              appState.doorStatus,
            ),

            buildSpeedRpmGauges(appState.gpsSpeed, appState.rpm),
            const SizedBox(height: 20),
            Text('Engine Temp (Last 20 Readings)'),
            SizedBox(
              height: 200,
              child: _buildTempChart(appState.engineTempHistory),
            ),
            const SizedBox(height: 20),
            Text('Battery Voltage (Last 20 Readings)'),
            SizedBox(
              height: 200,
              child: _buildTempChart(
                appState.batteryHistory,
                color: Colors.green,
              ),
            ),
            const SizedBox(height: 20),
            Text('Cabin Temp (Last 20 Readings)'),
            SizedBox(
              height: 200,
              child: _buildTempChart(
                appState.cabinTempHistory,
                color: Colors.blue,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({Key? key}) : super(key: key);

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final flutter_map.MapController _fmController = flutter_map.MapController();
  gmaps.GoogleMapController? _gmController;
  bool _followLocation = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<MyAppState>().addListener(_onLocationChanged);
    });
  }

  void _onLocationChanged() {
    final appState = context.read<MyAppState>();
    final newCenter = latlong2.LatLng(appState.latitude, appState.longitude);

    if (_followLocation) {
      _fmController.move(newCenter, _fmController.camera.zoom);
      _gmController?.animateCamera(
        gmaps.CameraUpdate.newLatLng(
          gmaps.LatLng(appState.latitude, appState.longitude),
        ),
      );
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    context.read<MyAppState>().removeListener(_onLocationChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    
    final appState = context.watch<MyAppState>();
    final flutterMap = flutter_map.FlutterMap(
      mapController: _fmController,
      options: flutter_map.MapOptions(
        initialCenter:
            latlong2.LatLng(appState.latitude, appState.longitude),
        initialZoom: 15,
        interactionOptions: const flutter_map.InteractionOptions(
          flags: flutter_map.InteractiveFlag.all,
          enableMultiFingerGestureRace: true,
          scrollWheelVelocity: 0.005,
        ),
        onPositionChanged: (_, byGesture) {
          if (byGesture && _followLocation) {
            setState(() => _followLocation = false);
          }
        },
      ),
      children: [
        
        // 1) Base tiles
        flutter_map.TileLayer(
          urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
          subdomains: ['a', 'b', 'c'],
        ),

        // 2) Polyline drawn before markers
        if (appState.route.isNotEmpty)
          flutter_map.PolylineLayer(
            polylines: [
              flutter_map.Polyline<latlong2.LatLng>(
                points: appState.route,
                strokeWidth: 4,
                color: Colors.deepOrange,
              ),
            ],
          ),

        
        
        // 3) Marker layer on top
        flutter_map.MarkerLayer(
          markers: [
            // 1) Start marker (green flag), anchored at the first route point
            flutter_map.Marker(
              point: appState.route.first,
              width: 45,
              height: 45,
              child: Container(
                // lift the icon above the line so it doesn’t get hidden
                margin: const EdgeInsets.only(bottom: 10),
                child: const Icon(Icons.flag, color: Colors.green, size: 45),
              ),
            ),

            // 2) End marker (orange pin), at the last route point
            flutter_map.Marker(
              point: appState.route.last,
              width: 45,
              height: 45,
              child: const Icon(
                Icons.location_on,
                color: Colors.deepOrange,
                size: 45,
              ),
            ),

            // 3) Intermediate “stop” markers (red flags)
            ...appState.stops.map(
              (p) => flutter_map.Marker(
                point: p,
                width: 30,
                height: 30,
                child: const Icon(Icons.flag, color: Colors.red, size: 30),
              ),
            ),
          ],
        ),
      ],
    );

    // GoogleMap branch (Mobile)
    final googleMap = gmaps.GoogleMap(
      onMapCreated: (c) => _gmController = c,
      onCameraMoveStarted: () {
        if (_followLocation) setState(() => _followLocation = false);
      },
      initialCameraPosition: gmaps.CameraPosition(
        target: gmaps.LatLng(appState.latitude, appState.longitude),
        zoom: 15,
      ),
      zoomGesturesEnabled: true,
      zoomControlsEnabled: true,
      markers: {
        for (var i = 0; i < appState.route.length; i++)
          gmaps.Marker(
            markerId: gmaps.MarkerId('pt_$i'),
            position: gmaps.LatLng(
              appState.route[i].latitude,
              appState.route[i].longitude,
            ),
            icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
              i == 0
                  ? gmaps.BitmapDescriptor.hueGreen
                  : i == appState.route.length - 1
                  ? gmaps.BitmapDescriptor.hueOrange
                  : gmaps.BitmapDescriptor.hueRed,
            ),
            infoWindow: gmaps.InfoWindow(
              title: 'Point ${i + 1}/${appState.route.length}',
              snippet:
                  'Lat ${appState.route[i].latitude.toStringAsFixed(4)}, '
                  'Lng ${appState.route[i].longitude.toStringAsFixed(4)}',
            ),
          ),
      },
      polylines: {
        if (appState.route.isNotEmpty)
          gmaps.Polyline(
            polylineId: const gmaps.PolylineId("route"),
            width: 4,
            color: Colors.deepOrange,
            points: appState.route
                .map((p) => gmaps.LatLng(p.latitude, p.longitude))
                .toList(),
          ),
      },
    );

    return Scaffold(
      appBar: AppBar(title: const Text("Car Location & Route")),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _followLocation = !_followLocation),
        child: Icon(_followLocation ? Icons.gps_fixed : Icons.gps_off),
      ),
      body: kIsWeb ? flutterMap : googleMap,
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late double highTemp, lowBattery, overSpeed;

  @override
  void initState() {
    super.initState();
    final s = context.read<MyAppState>();
    highTemp = s.highTempThreshold.clamp(40.0, 120.0);
    lowBattery = s.lowBatteryThreshold.clamp(9.0, 14.0);
    overSpeed = s.overSpeedThreshold.clamp(20.0, 200.0);
  }

  void _save() {
    final s = context.read<MyAppState>();
    s.highTempThreshold = highTemp;
    s.lowBatteryThreshold = lowBattery;
    s.overSpeedThreshold = overSpeed;
    s._saveSettings();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(title: Text('Alerts & Thresholds')),
      body: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            Text('High Engine Temp (°C): ${highTemp.toStringAsFixed(1)}'),
            Slider(
              min: 40,
              max: 120,
              divisions: 80,
              value: highTemp,
              label: highTemp.toStringAsFixed(1),
              onChanged: (v) => setState(() => highTemp = v),
            ),
            Text('Low Battery (V): ${lowBattery.toStringAsFixed(2)}'),
            Slider(
              min: 9,
              max: 14,
              divisions: 50,
              value: lowBattery,
              label: lowBattery.toStringAsFixed(2),
              onChanged: (v) => setState(() => lowBattery = v),
            ),
            Text('Over Speed (km/h): ${overSpeed.toStringAsFixed(0)}'),
            Slider(
              min: 20,
              max: 200,
              divisions: 180,
              value: overSpeed,
              label: overSpeed.toStringAsFixed(0),
              onChanged: (v) => setState(() => overSpeed = v),
            ),
            SizedBox(height: 24),
            ElevatedButton(onPressed: _save, child: Text('Save')),
          ],
        ),
      ),
    );
  }
}
