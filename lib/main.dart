import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
// import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';

import 'package:flutter_ble_lib/flutter_ble_lib.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:syncfusion_flutter_charts/sparkcharts.dart';
import 'package:wakelock/wakelock.dart';

enum ConnStatus { disconnected, disconnecting, scanning, connecting, connected }

class ChartCoords {
  ChartCoords({required this.x, required this.y});
  final int x, y;
}

void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'radar',
      home: RadarHomePage(title: 'Radar FFT'),
    );
  }
}

class RadarDataQueue {
  RadarDataQueue();
  Queue<ChartCoords> coord = Queue.from([ChartCoords(x: 0, y: 0)]);
  var index = 1;

  void updateRadarData(Uint8List radarRawData) {
    for (var i = 0; i < radarRawData.length - 2; i += 3) {
      while (coord.length > 6000 - 2) {
        coord.removeFirst();
      }
      coord.addLast(ChartCoords(
          y: ((0xf & radarRawData[i + 2]) << 8) | radarRawData[i], x: index++));
      coord.addLast(ChartCoords(
          y: ((0xf0 & radarRawData[i + 2]) << 8) | (radarRawData[i + 1]),
          x: index++));
    }
  }
}

class RadarHomePage extends StatefulWidget {
  RadarHomePage({Key? key, required this.title}) : super(key: key);

  // Creates the stateful home page of the application. holds Title

  final String title;

  @override
  _RadarHomePageState createState() => _RadarHomePageState();
}

class _RadarHomePageState extends State<RadarHomePage> {
  ConnStatus connStatus = ConnStatus.disconnected;
  PeripheralConnectionState periphConnStatus =
      PeripheralConnectionState.disconnected;

  String probabilities = "Null";
  String prediction = "Idle";

  static const int fps = 100;
  static const int timeWindow = 60;

  BleManager bleManager = BleManager();
  late Peripheral nrf52;
  late Peripheral hrband;
  late StreamSubscription radarStreamSub;
  late StreamSubscription bandStreamSub;
  //late StreamSubscription predStreamSub;

  int updateCnt = 0;

  RadarDataQueue radarData = RadarDataQueue();

  List<ChartCoords> chartData = [];

  final List<ChartCoords> data = List<ChartCoords>.generate(
    fps * timeWindow,
    (index) => ChartCoords(x: index, y: 0),
  );

  var count = 0;
//return characteristics of third service
  Future<List<Characteristic>> _getCharacteristics(Peripheral p) async {
    await p.discoverAllServicesAndCharacteristics();
    List<Service> services = await p.services();
    Service myService = services[2];
    List<Characteristic> chars = await p.characteristics(myService.uuid);
    return chars;
  }

  void _connStatusUpdater(PeripheralConnectionState event) {
    ConnStatus status;
    switch (event) {
      case PeripheralConnectionState.connecting:
        status = ConnStatus.connecting;
        break;
      case PeripheralConnectionState.connected:
        status = ConnStatus.connected;
        break;
      case PeripheralConnectionState.disconnecting:
        status = ConnStatus.disconnecting;
        break;
      default: // PeripheralConnectionState.disconnected;
        status = ConnStatus.disconnected;
    }
    setState(() {
      connStatus = status;
    });
  }

  void _connect() async {
    var bandConn = false, nrfConn = false;
    Wakelock.enable();
    await bleManager.createClient();
    setState(() {
      connStatus = ConnStatus.scanning;
    });
    Stream<ScanResult> periphStream = bleManager.startPeripheralScan();
    await for (ScanResult scanResult in periphStream) {
      if (scanResult.peripheral.name == "OnePlus 7T Pro") {
        print("Scanned ${scanResult.peripheral.name}, RSSI ${scanResult.rssi}");
        hrband = scanResult.peripheral;
        bandConn = true;
      }
      if (scanResult.peripheral.name == "nrf52") {
        print("Scanned ${scanResult.peripheral.name}, RSSI ${scanResult.rssi}");
        nrf52 = scanResult.peripheral;
        nrfConn = true;
      }
      if (bandConn) {
        bleManager.stopPeripheralScan();
      }
    }
    if (nrfConn) {
      nrf52.observeConnectionState(completeOnDisconnect: true).listen((event) {
        _connStatusUpdater(event);
      });
      await nrf52.connect(timeout: const Duration(seconds: 5));
      if (await nrf52.isConnected() != true) {
        await nrf52.disconnectOrCancelConnection();
        await bleManager.destroyClient();
      }
      await nrf52.discoverAllServicesAndCharacteristics();

      List<Characteristic> chars = await _getCharacteristics(nrf52);
      if (chars[0].isNotifiable) {
        radarStreamSub =
            chars[0].monitor().listen((event) => _onNewData(event));
      }
    }

    if (bandConn) {
      hrband.observeConnectionState(completeOnDisconnect: true).listen((event) {
        _connStatusUpdater(event);
      });
      await hrband.connect(timeout: const Duration(seconds: 5));
      if (await hrband.isConnected() != true) {
        await hrband.disconnectOrCancelConnection();
        await bleManager.destroyClient();
      }
      await hrband.discoverAllServicesAndCharacteristics();

      List<Characteristic> chars = await _getCharacteristics(hrband);
      if (chars[0].isNotifiable) {
        bandStreamSub = chars[0].monitor().listen((event) {
          setState(() {
            prediction = "HR: ${event[1]}";
          });
        });
      }
    }
    //chars[0].service.
    // if (chars[2].isNotifiable) {
    //   //radarStreamSub = chars[2].monitor().listen((event) => _onNewData(event));
    // }
  }

  void _disconnect() async {
    Wakelock.disable();
    radarStreamSub.cancel();

    await nrf52.disconnectOrCancelConnection();
    await bleManager.destroyClient();
  }

  //Handles Bluetooth connection and disconnection
  void _buttonConnectDisconnect() {
    if (connStatus == ConnStatus.disconnected) {
      _connect();
    } else {
      _disconnect();
    }
  }

  void _onNewData(Uint8List rawBLEdata) {
    setState(() {
      radarData.updateRadarData(rawBLEdata);
      updateCnt++;
    });
  }

  void _onNewDataHR(Uint8List rawBLEdata) {
    // setState(() {
    //   radarData.updateRadarData(rawBLEdata);
    //   updateCnt++;
    // });
  }

  Timer? timer;

  @override
  void initState() {
    super.initState();
    timer =
        Timer.periodic(const Duration(milliseconds: 200), _updateDataSource);
  }
  // SfSparkLineChart _getCartesianChart() {
  //   return SfSparkLineChart(data: List<int>.from([1, 2, 3, 4, 3, 2, 1]));
  // }

  ChartSeriesController? _chartSeriesController;

  /// Returns the realtime Cartesian line chart.
  SfCartesianChart _buildLiveLineChart() {
    return SfCartesianChart(
        plotAreaBorderWidth: 0,
        primaryXAxis:
            NumericAxis(majorGridLines: const MajorGridLines(width: 0)),
        primaryYAxis: NumericAxis(
            axisLine: const AxisLine(width: 0),
            majorTickLines: const MajorTickLines(size: 0)),
        series: <LineSeries<ChartCoords, int>>[
          LineSeries<ChartCoords, int>(
            onRendererCreated: (ChartSeriesController controller) {
              _chartSeriesController = controller;
            },
            dataSource: chartData, //List<ChartCoords>.from(radarData.coord),
            color: const Color.fromRGBO(192, 108, 132, 1),
            xValueMapper: (ChartCoords coord, _) => coord.x,
            yValueMapper: (ChartCoords coord, _) => coord.y,
            animationDuration: 0,
          )
        ]);
  }

  void _updateDataSource(Timer timer) {
    if (radarData.coord.isNotEmpty) {
      chartData.add(radarData.coord.removeFirst());
      if (chartData.length == 30) {
        chartData.removeAt(0);
        _chartSeriesController?.updateDataSource(
          addedDataIndexes: <int>[chartData.length - 1],
          removedDataIndexes: <int>[0],
        );
      } else {
        _chartSeriesController?.updateDataSource(
          addedDataIndexes: <int>[chartData.length - 1],
        );
      }
      count = count + 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text("temptitle"), //widget title
      ),
      body: _getBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _buttonConnectDisconnect(),
        label: Builder(
          builder: (context) {
            if (connStatus != ConnStatus.connected) {
              return Text("Connect");
            } else {
              return Text("Disconnect");
            }
          },
        ),
        icon: Icon(Icons.bluetooth),
      ),
      bottomNavigationBar: _getBottomAppBar(),
    );
  }

  Widget _getBody() {
    if (connStatus != ConnStatus.connected) {
      return Center(
        child: Icon(
          Icons.bluetooth_disabled_rounded,
          size: 240,
          color: Theme.of(context).disabledColor,
        ),
      );
    } else {
      return Column(
        children: [
          Expanded(
            child: _buildLiveLineChart(), //_getCartesianChart(),
            flex: 7,
          ),
          Expanded(
            child: Text(
              prediction,
              style: TextStyle(
                  color: Theme.of(context).primaryColor, fontSize: 28),
            ),
            flex: 2,
          ),
        ],
      );
    }
  }

  Widget _getBottomAppBar() {
    String msg;
    Color color;
    switch (connStatus) {
      case ConnStatus.connecting:
        msg = "Connecting";
        color = Colors.amber;
        break;
      case ConnStatus.connected:
        msg = "Connected";
        color = Colors.green;
        break;
      case ConnStatus.scanning:
        msg = "Scanning";
        color = Colors.amber;
        break;
      default:
        msg = "Disconnected";
        color = Theme.of(context).errorColor;
    }

    return BottomAppBar(
      child: Center(
        child: Text(
          msg,
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        heightFactor: 2,
      ),
      color: color,
    );
  }
}
