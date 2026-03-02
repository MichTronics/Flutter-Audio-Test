import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

void main() {
  runApp(const VuMeterApp());
}

// ─────────────────────────────────────────────
// App root
// ─────────────────────────────────────────────

class VuMeterApp extends StatelessWidget {
  const VuMeterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VU Meter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D0D0D),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E676),
          secondary: Color(0xFFFFD600),
        ),
      ),
      home: const VuMeterPage(),
    );
  }
}

// ─────────────────────────────────────────────
// Main page
// ─────────────────────────────────────────────

class VuMeterPage extends StatefulWidget {
  const VuMeterPage({super.key});

  @override
  State<VuMeterPage> createState() => _VuMeterPageState();
}

class _VuMeterPageState extends State<VuMeterPage>
    with SingleTickerProviderStateMixin {
  static const MethodChannel _nativeLoopbackChannel =
      MethodChannel('app.audio.loopback');

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  int _activeNumChannels = 2;

  // Current RMS dB level (dBFS, range: -60..0)
  double _dbLeft = _kMinDb;
  double _dbRight = _kMinDb;

  // Peak hold
  double _peakLeft = _kMinDb;
  double _peakRight = _kMinDb;
  int _peakHoldLeft = 0;
  int _peakHoldRight = 0;

  static const double _kMinDb = -60.0;
  static const double _kMaxDb = 0.0;
  static const double _kDecay = 1.5; // dB per audio chunk
  static const int _kPeakHold = 60; // chunks (~3 s)

  bool _isRecording = false;
  bool _isFileRecording = false;
  bool _isPlaying = false;
  bool _isDirectLoopback = false;
  StreamSubscription<Uint8List>? _audioSub;
  StreamSubscription<Uint8List>? _directLoopbackSub;
  StreamSubscription<PlayerState>? _playerSub;
  Timer? _noDataTimer;
  String? _lastRecordingPath;

  List<InputDevice> _devices = [];
  InputDevice? _selectedDevice;

  // Status / diagnostics
  String _statusMsg = 'Press START to begin';
  int _chunkCount = 0;
  bool _permissionGranted = false;

  // Drives repaint at screen refresh rate
  late final AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 16),
    )..repeat();
    _loadDevices();
  }

  @override
  void dispose() {
    _animController.dispose();
    _noDataTimer?.cancel();
    _audioSub?.cancel();
    _directLoopbackSub?.cancel();
    _playerSub?.cancel();
    _player.dispose();
    _recorder.dispose();
    super.dispose();
  }

  void _startNoDataWatchdog() {
    _noDataTimer?.cancel();
    _noDataTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_isRecording || _chunkCount > 0) return;

      _setStatus(
        'BLOCKED – Stream gestart maar geen audiodata ontvangen.\n'
        'Waarschijnlijk blokkeert Windows microfoon voor desktop apps.\n'
        'Ga naar Instellingen → Privacy en beveiliging → Microfoon\n'
        'en zet "Desktop-apps toegang geven" aan.',
      );
    });
  }

  // ── device enumeration ─────────────────────

  Future<void> _loadDevices() async {
    try {
      final devices = await _recorder.listInputDevices();
      if (mounted) {
        setState(() {
          _devices = devices;
          if (devices.isNotEmpty) _selectedDevice = devices.first;
        });
      }
    } catch (e) {
      _setStatus('Input devices ophalen mislukt: $e');
    }
  }

  Future<({Stream<Uint8List> stream, int channels, int sampleRate})>
      _startWithFallback() async {
    final attempts = <({InputDevice? device, int sampleRate, int channels})>[
      (device: _selectedDevice, sampleRate: 44100, channels: 2),
      (device: _selectedDevice, sampleRate: 44100, channels: 1),
      (device: null, sampleRate: 44100, channels: 1),
      (device: null, sampleRate: 48000, channels: 1),
    ];

    Object? lastError;

    for (final attempt in attempts) {
      final config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: attempt.sampleRate,
        numChannels: attempt.channels,
        device: attempt.device,
      );

      try {
        final stream = await _recorder.startStream(config);
        return (
          stream: stream,
          channels: attempt.channels,
          sampleRate: attempt.sampleRate,
        );
      } catch (e) {
        lastError = e;
      }
    }

    throw lastError ?? StateError('Onbekende audio startfout');
  }

  // ── amplitude calculation ──────────────────

  /// Converts raw PCM‑16LE bytes to dBFS for left + right channels.
  (double left, double right) _computeDb(Uint8List data, int numChannels) {
    if (data.isEmpty) return (_kMinDb, _kMinDb);

    final bytes = ByteData.sublistView(data);
    final totalBytes = bytes.lengthInBytes - (bytes.lengthInBytes % 2);

    double sumL = 0, sumR = 0;
    int countL = 0, countR = 0;

    if (numChannels == 1) {
      for (int i = 0; i < totalBytes; i += 2) {
        final s = bytes.getInt16(i, Endian.little);
        final n = s / 32768.0;
        sumL += n * n;
        countL++;
      }
      sumR = sumL;
      countR = countL;
    } else {
      final frameBytes = 4; // 16-bit stereo: L(2) + R(2)
      for (int i = 0; i + frameBytes <= totalBytes; i += frameBytes) {
        final l = bytes.getInt16(i, Endian.little) / 32768.0;
        final r = bytes.getInt16(i + 2, Endian.little) / 32768.0;
        sumL += l * l;
        sumR += r * r;
        countL++;
        countR++;
      }
    }

    double toDb(double sum, int count) {
      if (count == 0) return _kMinDb;
      final rms = sqrt(sum / count);
      if (rms == 0) return _kMinDb;
      return (20 * log(rms) / ln10).clamp(_kMinDb, _kMaxDb);
    }

    return (toDb(sumL, countL), toDb(sumR, countR));
  }

  // ── peak hold ─────────────────────────────

  void _updatePeak(double db, bool isLeft) {
    if (isLeft) {
      if (db >= _peakLeft) {
        _peakLeft = db;
        _peakHoldLeft = _kPeakHold;
      } else if (_peakHoldLeft > 0) {
        _peakHoldLeft--;
      } else {
        _peakLeft = max(_peakLeft - _kDecay, db);
      }
    } else {
      if (db >= _peakRight) {
        _peakRight = db;
        _peakHoldRight = _kPeakHold;
      } else if (_peakHoldRight > 0) {
        _peakHoldRight--;
      } else {
        _peakRight = max(_peakRight - _kDecay, db);
      }
    }
  }

  // ── recording controls ─────────────────────

  Future<void> _startRecording() async {
    if (_isFileRecording || _isDirectLoopback) {
      _setStatus('Stop eerst de bestandsopname (REC) voordat je live monitor start.');
      return;
    }

    setState(() {
      _statusMsg = 'Checking permission…';
      _chunkCount = 0;
    });

    bool hasPerm = false;
    try {
      hasPerm = await _recorder.hasPermission();
    } catch (e) {
      _setStatus('Permission check failed: $e');
      return;
    }

    setState(() => _permissionGranted = hasPerm);

    if (!hasPerm) {
      _setStatus(
        'BLOCKED – Microphone permission denied.\n'
        'Go to Windows Settings → Privacy & Security → Microphone\n'
        'and enable access for desktop apps.',
      );
      return;
    }

    try {
      final result = await _startWithFallback();
      final stream = result.stream;
      final channels = result.channels;
      setState(() {
        _isRecording = true;
        _activeNumChannels = channels;
        _statusMsg = 'Recording gestart… wachten op audiodata';
      });
      _startNoDataWatchdog();

      _audioSub = stream.listen(
        (data) {
          _noDataTimer?.cancel();
          final (l, r) = _computeDb(data, _activeNumChannels);
          setState(() {
            _chunkCount++;
            _statusMsg = 'Recording…  chunks: $_chunkCount  bytes: ${data.lengthInBytes}  ch: $_activeNumChannels';
            _dbLeft = l > _dbLeft ? l : max(_dbLeft - _kDecay, l);
            _dbRight = r > _dbRight ? r : max(_dbRight - _kDecay, r);
            _updatePeak(_dbLeft, true);
            _updatePeak(_dbRight, false);
          });
        },
        onError: (Object err, StackTrace st) {
          _setStatus('Stream error: $err');
          _stopRecording();
        },
        cancelOnError: false,
      );
    } catch (e) {
      _setStatus('Failed to start stream: $e');
    }
  }

  void _setStatus(String msg) {
    if (mounted) setState(() => _statusMsg = msg);
  }

  Future<void> _stopRecording() async {
    _noDataTimer?.cancel();
    await _audioSub?.cancel();
    _audioSub = null;
    await _recorder.stop();
    setState(() {
      _isRecording = false;
      _dbLeft = _kMinDb;
      _dbRight = _kMinDb;
      _peakLeft = _kMinDb;
      _peakRight = _kMinDb;
      _statusMsg = 'Stopped. Total chunks received: $_chunkCount';
    });
  }

  Future<void> _toggleFileRecording() async {
    if (_isFileRecording) {
      await _stopFileRecording();
      return;
    }

    if (_isRecording || _isDirectLoopback) {
      _setStatus('Stop eerst live monitor (START/STOP) voordat je REC start.');
      return;
    }

    if (_isPlaying) {
      await _player.stop();
    }

    bool hasPerm = false;
    try {
      hasPerm = await _recorder.hasPermission();
    } catch (e) {
      _setStatus('Permission check failed: $e');
      return;
    }

    if (!hasPerm) {
      _setStatus(
        'BLOCKED – Microphone permission denied.\n'
        'Enable desktop app microphone access in Windows settings.',
      );
      return;
    }

    final filePath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}vu_record_${DateTime.now().millisecondsSinceEpoch}.wav';

    final config = RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: 44100,
      numChannels: 1,
      device: _selectedDevice,
    );

    try {
      await _recorder.start(config, path: filePath);
      setState(() {
        _isFileRecording = true;
        _lastRecordingPath = filePath;
        _statusMsg = 'REC… opnemen naar: $filePath';
      });
    } catch (e) {
      _setStatus('Bestandsopname starten mislukt: $e');
    }
  }

  Future<void> _stopFileRecording() async {
    try {
      final path = await _recorder.stop();
      setState(() {
        _isFileRecording = false;
        if (path != null && path.isNotEmpty) {
          _lastRecordingPath = path;
        }
        _statusMsg = _lastRecordingPath == null
            ? 'REC gestopt, maar geen bestandspad ontvangen.'
            : 'REC gestopt. Bestand klaar voor playback.';
      });
    } catch (e) {
      setState(() => _isFileRecording = false);
      _setStatus('Bestandsopname stoppen mislukt: $e');
    }
  }

  Future<void> _playLastRecording() async {
    if (_isRecording || _isFileRecording || _isDirectLoopback) {
      _setStatus('Stop eerst opname/monitoring voordat je afspeelt.');
      return;
    }

    final path = _lastRecordingPath;
    if (path == null || !File(path).existsSync()) {
      _setStatus('Geen opnamebestand gevonden om af te spelen.');
      return;
    }

    try {
      await _player.stop();
      setState(() {
        _isPlaying = true;
        _statusMsg = 'Playback… $path';
      });

      await _player.play(DeviceFileSource(path));
      _playerSub ??= _player.onPlayerStateChanged.listen((state) {
        if (!mounted) return;
        if (state == PlayerState.completed || state == PlayerState.stopped) {
          setState(() {
            _isPlaying = false;
            _statusMsg = 'Playback klaar.';
          });
        }
      });
    } catch (e) {
      setState(() => _isPlaying = false);
      _setStatus('Playback mislukt: $e');
    }
  }

  Future<void> _toggleDirectLoopback() async {
    if (_isDirectLoopback) {
      try {
        await _directLoopbackSub?.cancel();
        _directLoopbackSub = null;
        await _recorder.stop();
        await _nativeLoopbackChannel.invokeMethod<void>('stopLoopback');
      } catch (_) {}

      setState(() {
        _isDirectLoopback = false;
        _statusMsg = 'Direct loopback gestopt.';
      });
      return;
    }

    if (_isRecording || _isFileRecording || _isPlaying) {
      _setStatus('Direct loopback kan nu niet starten (stop eerst lopende actie).');
      return;
    }

    bool hasPerm = false;
    try {
      hasPerm = await _recorder.hasPermission();
    } catch (e) {
      _setStatus('Permission check failed: $e');
      return;
    }

    if (!hasPerm) {
      _setStatus(
        'BLOCKED – Microphone permission denied.\n'
        'Enable desktop app microphone access in Windows settings.',
      );
      return;
    }

    try {
      final result = await _startWithFallback();
      final stream = result.stream;
      final channels = result.channels;
      final sampleRate = result.sampleRate;

      await _nativeLoopbackChannel.invokeMethod<void>('startLoopback', {
        'sampleRate': sampleRate,
        'numChannels': channels,
      });

      setState(() {
        _isDirectLoopback = true;
        _activeNumChannels = channels;
        _chunkCount = 0;
        _statusMsg = 'Direct loopback actief… (${sampleRate}Hz, ${channels}ch)';
      });
      _startNoDataWatchdog();

      _directLoopbackSub = stream.listen(
        (data) async {
          _noDataTimer?.cancel();
          try {
            await _nativeLoopbackChannel.invokeMethod<void>('pushPcm', data);
          } catch (e) {
            await _toggleDirectLoopback();
            _setStatus('Direct loopback push fout: $e');
            return;
          }

          final (l, r) = _computeDb(data, _activeNumChannels);
          setState(() {
            _chunkCount++;
            _statusMsg =
                'Direct loopback… chunks: $_chunkCount bytes: ${data.lengthInBytes}';
            _dbLeft = l > _dbLeft ? l : max(_dbLeft - _kDecay, l);
            _dbRight = r > _dbRight ? r : max(_dbRight - _kDecay, r);
            _updatePeak(_dbLeft, true);
            _updatePeak(_dbRight, false);
          });
        },
        onError: (e, st) async {
          await _toggleDirectLoopback();
          _setStatus('Direct loopback stream error: $e');
        },
      );
    } catch (e) {
      setState(() {
        _isDirectLoopback = false;
      });
      _setStatus('Direct loopback starten mislukt: $e');
    }
  }

  // ── build ──────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildMeter()),
            _buildDbReadout(),
            const SizedBox(height: 10),
            _buildStatusBar(),
            const SizedBox(height: 12),
            _buildDeviceSelector(),
            const SizedBox(height: 12),
            _buildStartStopButton(),
            const SizedBox(height: 12),
            _buildRecordPlayButtons(),
            const SizedBox(height: 12),
            _buildLoopbackButton(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF222222))),
      ),
      child: const Center(
        child: Text(
          'VU METER',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: 8,
            color: Color(0xFFAAAAAA),
          ),
        ),
      ),
    );
  }

  Widget _buildMeter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 20, 16, 8),
      child: AnimatedBuilder(
        animation: _animController,
        builder: (context, _) {
          return CustomPaint(
            painter: VuMeterPainter(
              dbLeft: _dbLeft,
              dbRight: _dbRight,
              peakLeft: _peakLeft,
              peakRight: _peakRight,
              minDb: _kMinDb,
              maxDb: _kMaxDb,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }

  Widget _buildDbReadout() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _dbChip('L', _dbLeft),
        const SizedBox(width: 40),
        _dbChip('R', _dbRight),
      ],
    );
  }

  Color _levelColor(double db) {
    if (db >= -6) return const Color(0xFFFF1744);
    if (db >= -18) return const Color(0xFFFFD600);
    return const Color(0xFF00E676);
  }

  Widget _dbChip(String label, double db) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            letterSpacing: 3,
            color: Color(0xFF555555),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${db.toStringAsFixed(1)} dBFS',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            fontFamily: 'Courier New',
            color: _levelColor(db),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBar() {
    final bool isError = _statusMsg.startsWith('BLOCKED') ||
        _statusMsg.startsWith('Failed') ||
        _statusMsg.startsWith('Stream error') ||
        _statusMsg.startsWith('Permission check');
    final color = isError
        ? const Color(0xFFFF5252)
        : _isRecording
            ? const Color(0xFF00E676)
            : const Color(0xFF555555);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF161616),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Text(
          _statusMsg,
          style: TextStyle(fontSize: 11, color: color, fontFamily: 'Courier New'),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildDeviceSelector() {
    if (_devices.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          'No input devices found',
          style: TextStyle(color: Color(0xFF555555)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: DropdownButtonFormField<InputDevice>(
        value: _selectedDevice,
        isExpanded: true,
        dropdownColor: const Color(0xFF1C1C1C),
        decoration: InputDecoration(
          labelText: 'Input device',
          labelStyle: const TextStyle(color: Color(0xFF777777), fontSize: 12),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          enabledBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: Color(0xFF333333)),
            borderRadius: BorderRadius.circular(8),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: Color(0xFF00E676)),
            borderRadius: BorderRadius.circular(8),
          ),
          disabledBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: Color(0xFF222222)),
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        items: _devices.map((d) {
          return DropdownMenuItem(
            value: d,
            child: Text(
              d.label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          );
        }).toList(),
        onChanged:
            (_isRecording || _isFileRecording || _isDirectLoopback)
                ? null
                : (d) => setState(() => _selectedDevice = d),
      ),
    );
  }

  Widget _buildStartStopButton() {
    final recording = _isRecording;
    final disabled = _isFileRecording || _isDirectLoopback;
    return SizedBox(
      width: 220,
      height: 52,
      child: ElevatedButton.icon(
        onPressed: disabled ? null : (recording ? _stopRecording : _startRecording),
        icon: Icon(
          recording ? Icons.stop_circle_outlined : Icons.mic,
          size: 22,
        ),
        label: Text(
          recording ? 'STOP' : 'START',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 4,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor:
              recording ? const Color(0xFF8B0000) : const Color(0xFF1B5E20),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }

  Widget _buildRecordPlayButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 160,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: (_isRecording || _isDirectLoopback) ? null : _toggleFileRecording,
            icon: Icon(_isFileRecording ? Icons.stop : Icons.fiber_manual_record),
            label: Text(
              _isFileRecording ? 'STOP REC' : 'REC',
              style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  _isFileRecording ? const Color(0xFF8B0000) : const Color(0xFFB71C1C),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 160,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: (_isFileRecording || _isRecording || _isDirectLoopback)
                ? null
                : _playLastRecording,
            icon: Icon(_isPlaying ? Icons.volume_up : Icons.play_arrow),
            label: const Text(
              'PLAY LAST',
              style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0D47A1),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoopbackButton() {
    return SizedBox(
      width: 332,
      height: 48,
      child: ElevatedButton.icon(
        onPressed: (_isRecording || _isFileRecording || _isPlaying)
            ? null
            : _toggleDirectLoopback,
        icon: Icon(_isDirectLoopback ? Icons.stop : Icons.hearing),
        label: Text(
          _isDirectLoopback ? 'STOP DIRECT LOOPBACK' : 'START DIRECT LOOPBACK',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF4A148C),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Custom painter – LED-segment VU meter
// ─────────────────────────────────────────────

class VuMeterPainter extends CustomPainter {
  final double dbLeft;
  final double dbRight;
  final double peakLeft;
  final double peakRight;
  final double minDb;
  final double maxDb;

  static const int _kSegments = 40;
  static const double _kSegmentGap = 2.5;

  VuMeterPainter({
    required this.dbLeft,
    required this.dbRight,
    required this.peakLeft,
    required this.peakRight,
    required this.minDb,
    required this.maxDb,
  });

  /// Normalises a dB value to 0..1 (0 = silence, 1 = full scale).
  double _frac(double db) =>
      ((db - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);

  /// Bright segment color at the given segment index (0 = bottom).
  Color _segColor(int seg) {
    final f = seg / _kSegments;
    if (f >= 0.875) return const Color(0xFFFF1744); // top 12.5 % → red
    if (f >= 0.700) return const Color(0xFFFFD600); // next 17.5 % → yellow
    return const Color(0xFF00E676);                 // rest → green
  }

  Color _segColorDim(int seg) {
    final c = _segColor(seg);
    return Color.fromARGB(
      255,
      (c.red * 0.10).round(),
      (c.green * 0.10).round(),
      (c.blue * 0.10).round(),
    );
  }

  void _drawChannel({
    required Canvas canvas,
    required Rect rect,
    required double db,
    required double peak,
  }) {
    final segH =
        (rect.height - (_kSegments - 1) * _kSegmentGap) / _kSegments;
    final litCount = (_frac(db) * _kSegments).round();
    final peakIdx = (_frac(peak) * (_kSegments - 1)).round();

    final paint = Paint()..style = PaintingStyle.fill;

    for (int i = 0; i < _kSegments; i++) {
      // i=0 is the bottom (quietest), i=_kSegments-1 is the top (loudest)
      final top = rect.bottom - (i + 1) * segH - i * _kSegmentGap;
      final segRect = Rect.fromLTWH(rect.left, top, rect.width, segH);
      final rr = RRect.fromRectAndRadius(segRect, const Radius.circular(2));

      final lit = i < litCount;

      // Subtle glow behind lit segments
      if (lit) {
        canvas.drawRRect(
          rr,
          Paint()
            ..color = _segColor(i).withOpacity(0.22)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
      }

      paint.color = lit ? _segColor(i) : _segColorDim(i);
      canvas.drawRRect(rr, paint);
    }

    // Peak indicator (bright, with white highlight)
    if (peak > minDb) {
      final pTop =
          rect.bottom - (peakIdx + 1) * segH - peakIdx * _kSegmentGap;
      final pr = Rect.fromLTWH(rect.left, pTop, rect.width, segH);
      final prr = RRect.fromRectAndRadius(pr, const Radius.circular(2));

      canvas.drawRRect(
        prr,
        Paint()
          ..color = _segColor(peakIdx).withOpacity(0.3)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      canvas.drawRRect(prr, Paint()..color = _segColor(peakIdx));
      canvas.drawRRect(
        prr,
        Paint()
          ..color = Colors.white.withOpacity(0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8,
      );
    }
  }

  void _drawScale(Canvas canvas, double x, double top, double height) {
    const marks = <int>[0, -3, -6, -9, -12, -18, -24, -36, -48, -60];
    final textPaint = TextStyle(
      color: Colors.grey.shade500,
      fontSize: 9.5,
      fontFamily: 'Courier New',
    );
    final tickPaint = Paint()
      ..color = Colors.grey.shade600
      ..strokeWidth = 1;

    for (final db in marks) {
      final f = _frac(db.toDouble());
      final y = top + height - f * height;

      canvas.drawLine(Offset(x, y), Offset(x + 8, y), tickPaint);

      final label = db == 0 ? ' 0' : db.toString();
      final tp = TextPainter(
        text: TextSpan(text: label, style: textPaint),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + 11, y - tp.height / 2));
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    const scaleWidth = 42.0;
    const gap = 12.0;
    final chW = (size.width - scaleWidth - gap) / 2;

    final leftRect = Rect.fromLTWH(0, 0, chW, size.height - 18);
    final rightRect = Rect.fromLTWH(chW + gap, 0, chW, size.height - 18);

    // Panel backgrounds
    const bg = Color(0xFF101010);
    final bgPaint = Paint()..color = bg;
    canvas.drawRRect(
      RRect.fromRectAndRadius(leftRect.inflate(3), const Radius.circular(5)),
      bgPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rightRect.inflate(3), const Radius.circular(5)),
      bgPaint,
    );

    _drawChannel(canvas: canvas, rect: leftRect, db: dbLeft, peak: peakLeft);
    _drawChannel(
        canvas: canvas, rect: rightRect, db: dbRight, peak: peakRight);

    // Scale to the right of both channels
    _drawScale(canvas, rightRect.right + 6, 0, leftRect.height);

    // Channel labels below bars
    _paintCenteredText(canvas, 'L', leftRect.center.dx, leftRect.bottom + 5);
    _paintCenteredText(canvas, 'R', rightRect.center.dx, rightRect.bottom + 5);
  }

  void _paintCenteredText(Canvas canvas, String text, double cx, double y) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Color(0xFF444444),
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, y));
  }

  @override
  bool shouldRepaint(VuMeterPainter old) =>
      old.dbLeft != dbLeft ||
      old.dbRight != dbRight ||
      old.peakLeft != peakLeft ||
      old.peakRight != peakRight;
}
