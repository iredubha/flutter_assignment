import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const cream = Color(0xFFF6F1E7);
const sage = Color(0xFF8FAE8B);
const forest = Color(0xFF4F6F52);

const softShadow = [
  BoxShadow(color: Color(0x14000000), blurRadius: 14, offset: Offset(0, 6)),
];

/// true  = onboarding plays every time the app starts (good for demos)
/// false = onboarding only plays the first time
const kAlwaysShowOnboarding = true;

/// Meditation timer length. 5 seconds for the demo.
/// For the real app change to 300 (= 5 minutes).
const kMeditateSeconds = 5;

String dayKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// DEMO: shifts the app's "today" by N days so you can show the teacher
/// what happens tomorrow / when a day is missed, without waiting for 00:00.
/// Real app: keep it at 0 (or delete the demo card in Settings).
int debugDayOffset = 0;
DateTime appNow() => DateTime.now().add(Duration(days: debugDayOffset));

// ───────────────────────── DATA ─────────────────────────

class HabitDef {
  final String emoji, name, identity;
  final int timerSeconds; // 0 = no timer
  const HabitDef(this.emoji, this.name, this.identity, {this.timerSeconds = 0});
}

const presets = [
  HabitDef('💧', 'Drink water', 'I am someone who keeps my body hydrated.'),
  HabitDef('📖', 'Read 10 pages', 'I am a reader.'),
  HabitDef('🚶', 'Walk 20 minutes', 'I am someone who moves every day.'),
  HabitDef(
    '🧘',
    'Meditate 5 minutes',
    'I am calm and present.',
    timerSeconds: kMeditateSeconds,
  ),
  HabitDef('✍️', 'Write in a journal', 'I am someone who reflects on my day.'),
  HabitDef(
    '🛏️',
    'Make the bed',
    'I am someone who starts the day with order.',
  ),
];

/// Saved progress of ONE habit's tree.
class HabitProgress {
  List<String> runDays;
  int leaves;
  HabitProgress(this.runDays, this.leaves);
}

class AppState extends ChangeNotifier {
  late SharedPreferences _prefs;
  bool loaded = false;
  bool onboarded = false;

  String? chosen; // chosen habit name
  List<String> runDays = []; // days confirmed in the CURRENT habit's tree
  int leafCount = 0; // leaves on the CURRENT habit's tree
  Map<String, HabitProgress> progress = {}; // saved trees of every habit
  List<String> log = []; // "yyyy-MM-dd|habit" history of all confirmations
  List<HabitDef> custom = [];
  int water = 0; // bottles of water collected (shared by all habits)

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    chosen = _prefs.getString('chosen');
    runDays = _prefs.getStringList('runDays') ?? [];
    log = _prefs.getStringList('log2') ?? [];
    custom = (_prefs.getStringList('custom') ?? []).map((s) {
      final i = s.indexOf('|');
      final name = s.substring(i + 1);
      return HabitDef(s.substring(0, i), name, 'I am someone who does: $name.');
    }).toList();
    water = _prefs.getInt('water') ?? 0;
    leafCount = _prefs.getInt('leafCount') ?? runDays.length;
    debugDayOffset = _prefs.getInt('dayOffset') ?? 0; // DEMO

    final raw = _prefs.getString('progress');
    if (raw != null) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        progress = m.map(
          (k, v) => MapEntry(
            k,
            HabitProgress(
              List<String>.from(v['d'] as List),
              (v['l'] as num).toInt(),
            ),
          ),
        );
      } catch (_) {
        progress = {};
      }
    }
    // kAlwaysShowOnboarding = true: intro plays on EVERY app start.
    // false: only the first time (Settings > Replay intro to see it again).
    onboarded = kAlwaysShowOnboarding
        ? false
        : (_prefs.getBool('onboarded') ?? false);
    loaded = true;
    notifyListeners();
  }

  /// Copy the current tree into the saved map.
  void _stash() {
    if (chosen != null) {
      progress[chosen!] = HabitProgress(List.of(runDays), leafCount);
    }
  }

  Future<void> _save() async {
    _stash();
    if (chosen == null) {
      await _prefs.remove('chosen');
    } else {
      await _prefs.setString('chosen', chosen!);
    }
    await _prefs.setStringList('runDays', runDays);
    await _prefs.setStringList('log2', log);
    await _prefs.setStringList(
      'custom',
      custom.map((h) => '${h.emoji}|${h.name}').toList(),
    );
    await _prefs.setInt('water', water);
    await _prefs.setInt('leafCount', leafCount);
    await _prefs.setString(
      'progress',
      jsonEncode(
        progress.map((k, v) => MapEntry(k, {'d': v.runDays, 'l': v.leaves})),
      ),
    );
    await _prefs.setBool('onboarded', onboarded);
    await _prefs.setInt('dayOffset', debugDayOffset); // DEMO
  }

  void finishOnboarding() {
    onboarded = true;
    _save();
    notifyListeners();
  }

  void replayOnboarding() {
    onboarded = false;
    notifyListeners();
  }

  List<HabitDef> get library => [...presets, ...custom];

  HabitDef? get chosenDef {
    if (chosen == null) return null;
    return library.firstWhere(
      (h) => h.name == chosen,
      orElse: () => HabitDef('✨', chosen!, 'I am someone who does: $chosen.'),
    );
  }

  String get _today => dayKey(appNow());

  bool get doneToday => runDays.contains(_today);

  /// A tree dies if its last confirmed day is older than yesterday.
  static bool _isDead(List<String> days) {
    if (days.isEmpty) return false;
    final n = appNow();
    final yesterday = dayKey(DateTime(n.year, n.month, n.day - 1));
    final last = (List.of(days)..sort()).last;
    return last.compareTo(yesterday) < 0;
  }

  bool get dead => _isDead(runDays);
  int get leaves => leafCount;
  int get streak => dead ? 0 : runDays.length;

  // Stats of any habit (used by the Habits list)
  int streakFor(String name) {
    if (name == chosen) return streak;
    final p = progress[name];
    if (p == null || _isDead(p.runDays)) return 0;
    return p.runDays.length;
  }

  int leavesFor(String name) =>
      name == chosen ? leafCount : (progress[name]?.leaves ?? 0);

  bool deadFor(String name) => name == chosen
      ? dead
      : (progress[name] != null && _isDead(progress[name]!.runDays));

  /// Switching habits SAVES the current tree and restores the other one.
  void chooseHabit(HabitDef h) {
    if (chosen != h.name) {
      _stash();
      chosen = h.name;
      final p = progress[h.name];
      runDays = p != null ? List.of(p.runDays) : [];
      leafCount = p?.leaves ?? 0;
    }
    _save();
    notifyListeners();
  }

  void completeToday() {
    if (chosen == null) return;
    if (dead) {
      runDays = [];
      leafCount = 0;
    }
    if (!runDays.contains(_today)) {
      runDays.add(_today);
      log.add('$_today|$chosen');
      water++;
    }
    _save();
    notifyListeners();
  }

  void undoToday() {
    if (runDays.remove(_today)) {
      log.remove('$_today|$chosen');
      if (water > 0) {
        water--;
      } else if (leafCount > 0) {
        leafCount--;
      }
    }
    _save();
    notifyListeners();
  }

  /// Use 1 bottle of water to grow 1 leaf.
  bool waterTree() {
    if (water <= 0 || dead) return false;
    water--;
    leafCount++;
    _save();
    notifyListeners();
    return true;
  }

  HabitDef addCustom(String name) {
    final existing = library.where((h) => h.name == name);
    if (existing.isNotEmpty) return existing.first;
    final h = HabitDef('✨', name, 'I am someone who does: $name.');
    custom.add(h);
    _save();
    notifyListeners();
    return h;
  }

  void removeCustom(String name) {
    if (name == chosen) return;
    custom.removeWhere((h) => h.name == name);
    progress.remove(name);
    _save();
    notifyListeners();
  }

  void resetHistory() {
    runDays = [];
    leafCount = 0;
    progress = {};
    log = [];
    water = 0;
    _save();
    notifyListeners();
  }

  // ── DEMO: time travel ──

  /// Move the app's "today" forward by [n] days.
  void debugSkipDays(int n) {
    debugDayOffset += n;
    _save();
    notifyListeners();
  }

  /// Back to the real date.
  void debugResetTime() {
    debugDayOffset = 0;
    _save();
    notifyListeners();
  }
}

// ───────────────────────── APP ─────────────────────────

void main() => runApp(const GrowApp());

class GrowApp extends StatelessWidget {
  const GrowApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'GrowUp',
    theme: ThemeData(
      scaffoldBackgroundColor: cream,
      colorScheme: ColorScheme.fromSeed(seedColor: sage),
      useMaterial3: true,
    ),
    home: const SplashScreen(),
  );
}

// ───────────────────────── SPLASH ─────────────────────────

/// Animated splash: a tree grows leaf by leaf, the title fades in,
/// then the app fades into the Shell (onboarding or garden).
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _grow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..forward();
  late final AnimationController _sway = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
  )..repeat();

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 2600), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 500),
          pageBuilder: (_, __, ___) => const Shell(),
          transitionsBuilder: (_, a, __, child) =>
              FadeTransition(opacity: a, child: child),
        ),
      );
    });
  }

  @override
  void dispose() {
    _grow.dispose();
    _sway.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFBF8F0), Color(0xFFE3ECDA)],
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 280,
              height: 280,
              child: AnimatedBuilder(
                animation: Listenable.merge([_grow, _sway]),
                builder: (_, __) => CustomPaint(
                  size: Size.infinite,
                  painter: TreePainter(
                    leaves: (Curves.easeOut.transform(_grow.value) * 16)
                        .floor(),
                    streak: 0,
                    alive: true,
                    t: _sway.value,
                    grow: 1,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            FadeTransition(
              opacity: CurvedAnimation(
                parent: _grow,
                curve: const Interval(0.5, 1.0),
              ),
              child: const Column(
                children: [
                  Text(
                    'GrowUp',
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                      color: forest,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Tiny habits, big trees 🌱',
                    style: TextStyle(fontSize: 15, color: Colors.black54),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final app = AppState();
  int tab = 0;

  @override
  void initState() {
    super.initState();
    app.init();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        if (!app.loaded) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (!app.onboarded) {
          return OnboardingScreen(
            onDone: () {
              setState(() => tab = 0);
              app.finishOnboarding();
            },
          );
        }
        return Scaffold(
          body: SafeArea(
            child: IndexedStack(
              index: tab,
              children: [
                GardenPage(app: app),
                HabitsPage(app: app),
                ActivitiesPage(app: app),
                SettingsPage(app: app),
              ],
            ),
          ),
          bottomNavigationBar: NavigationBar(
            backgroundColor: Colors.white,
            elevation: 8,
            shadowColor: Colors.black26,
            indicatorColor: sage.withValues(alpha: 0.35),
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.park_outlined),
                selectedIcon: Icon(Icons.park, color: forest),
                label: 'Garden',
              ),
              NavigationDestination(
                icon: Icon(Icons.view_agenda_outlined),
                selectedIcon: Icon(Icons.view_agenda, color: forest),
                label: 'Habits',
              ),
              NavigationDestination(
                icon: Icon(Icons.history),
                selectedIcon: Icon(Icons.history, color: forest),
                label: 'Activities',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings, color: forest),
                label: 'Settings',
              ),
            ],
          ),
        );
      },
    );
  }
}

// ───────────────────────── ONBOARDING ─────────────────────────

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pc = PageController();
  int page = 0;
  static const total = 4;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = page == total - 1;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFBF8F0), Color(0xFFE3ECDA)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8, top: 4),
                  child: TextButton(
                    onPressed: widget.onDone,
                    child: Text(
                      last ? '' : 'Skip',
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: PageView(
                  controller: _pc,
                  onPageChanged: (i) => setState(() => page = i),
                  children: const [
                    _IntroPane(),
                    _EarnPane(),
                    _WaterPane(),
                    _StreakPane(),
                  ],
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < total; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: i == page ? 24 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == page ? forest : sage.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
                child: SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: forest,
                      shape: const StadiumBorder(),
                      textStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    onPressed: () {
                      if (last) {
                        widget.onDone();
                      } else {
                        _pc.nextPage(
                          duration: const Duration(milliseconds: 350),
                          curve: Curves.easeOut,
                        );
                      }
                    },
                    child: Text(last ? 'Get started 🌱' : 'Next'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnbFrame extends StatelessWidget {
  final String title, body;
  final Widget child;
  const _OnbFrame({
    required this.title,
    required this.body,
    required this.child,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Column(
      children: [
        const SizedBox(height: 8),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: forest,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          body,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 15,
            height: 1.4,
            color: Colors.black54,
          ),
        ),
        const SizedBox(height: 16),
        Expanded(child: child),
      ],
    ),
  );
}

/// Small animated tree used by the onboarding pages.
class _MiniTree extends StatefulWidget {
  final int leaves;
  final bool alive;
  const _MiniTree({required this.leaves, this.alive = true});
  @override
  State<_MiniTree> createState() => _MiniTreeState();
}

class _MiniTreeState extends State<_MiniTree> with TickerProviderStateMixin {
  late final AnimationController _sway = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
  )..repeat();
  late final AnimationController _grow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
    value: 1,
  );

  @override
  void didUpdateWidget(_MiniTree old) {
    super.didUpdateWidget(old);
    if (widget.leaves > old.leaves) _grow.forward(from: 0);
  }

  @override
  void dispose() {
    _sway.dispose();
    _grow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_sway, _grow]),
    builder: (_, __) => CustomPaint(
      size: Size.infinite,
      painter: TreePainter(
        leaves: widget.leaves,
        streak: widget.leaves,
        alive: widget.alive,
        t: _sway.value,
        grow: Curves.easeOutBack.transform(_grow.value),
      ),
    ),
  );
}

// Page 1: pick a habit
class _IntroPane extends StatelessWidget {
  const _IntroPane();
  @override
  Widget build(BuildContext context) => _OnbFrame(
    title: 'Grow a tree with a tiny habit',
    body: 'Pick one habit, do it every day, and watch your own tree grow. Some habits, like meditation, even come with a built-in timer.',
    child: Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutBack,
        builder: (_, v, child) => Transform.scale(
          scale: 0.8 + 0.2 * v,
          child: Opacity(opacity: v.clamp(0.0, 1.0), child: child),
        ),
        child: Container(
          width: 260,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: cream,
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 16,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('🧘', style: TextStyle(fontSize: 72)),
              SizedBox(height: 12),
              Text(
                'Meditate 5 minutes',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: forest,
                ),
              ),
              SizedBox(height: 14),
              Text(
                'IDENTITY',
                style: TextStyle(
                  letterSpacing: 2,
                  fontSize: 11,
                  color: Colors.black45,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'I am calm and present.',
                style: TextStyle(
                  fontSize: 15,
                  fontStyle: FontStyle.italic,
                  color: Colors.black87,
                ),
              ),
              SizedBox(height: 12),
              Text(
                '⏱ Timer habit',
                style: TextStyle(color: forest, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// Page 2: do the habit, earn a bottle
class _EarnPane extends StatefulWidget {
  const _EarnPane();
  @override
  State<_EarnPane> createState() => _EarnPaneState();
}

class _EarnPaneState extends State<_EarnPane> {
  bool done = false;
  int burst = 0;

  @override
  Widget build(BuildContext context) => _OnbFrame(
    title: 'Do it, earn water',
    body: 'Every day you complete your habit you get 1 bottle of water 💧. Try it: tap the card.',
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.topCenter,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(26),
                  boxShadow: softShadow,
                ),
                child: Material(
                  color: done ? const Color(0xFFDCE7D8) : Colors.white,
                  borderRadius: BorderRadius.circular(26),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(26),
                    onTap: () {
                      if (done) return;
                      HapticFeedback.mediumImpact();
                      setState(() {
                        done = true;
                        burst++;
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 56,
                            height: 56,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: sage.withValues(alpha: 0.25),
                              shape: BoxShape.circle,
                            ),
                            child: const Text(
                              '💧',
                              style: TextStyle(fontSize: 28),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Drink water',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                done ? 'Done today ✓' : 'Tap to confirm today',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 16),
                          Icon(
                            done
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: forest,
                            size: 28,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (burst > 0)
                Positioned(
                  top: -8,
                  child: TweenAnimationBuilder<double>(
                    key: ValueKey(burst),
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 1000),
                    builder: (_, v, __) => Opacity(
                      opacity: (1 - v).clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: Offset(0, -70 * v),
                        child: const Text(
                          '+1 💧',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF3F8EDB),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          _StatChip('💧', '${done ? 1 : 0} bottle'),
          const SizedBox(height: 12),
          SizedBox(
            height: 40,
            child: done
                ? TextButton(
                    onPressed: () => setState(() => done = false),
                    child: const Text('Try again'),
                  )
                : null,
          ),
        ],
      ),
    ),
  );
}

// Page 3: water the tree, get a leaf
class _WaterPane extends StatefulWidget {
  const _WaterPane();
  @override
  State<_WaterPane> createState() => _WaterPaneState();
}

class _WaterPaneState extends State<_WaterPane> {
  int water = 1;
  int leaves = 3;

  @override
  Widget build(BuildContext context) => _OnbFrame(
    title: 'Water your tree',
    body: 'Spend a bottle to grow 1 new leaf 🍃. One day of effort = one leaf on your tree.',
    child: Column(
      children: [
        Expanded(child: _MiniTree(leaves: leaves)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF3F8EDB),
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.black12,
              shape: const StadiumBorder(),
              textStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            onPressed: water > 0
                ? () {
                    HapticFeedback.lightImpact();
                    setState(() {
                      water--;
                      leaves++;
                    });
                  }
                : null,
            icon: const Icon(Icons.water_drop),
            label: Text(
              water > 0
                  ? 'Water tree  ·  $water 💧'
                  : 'A new leaf grew 🍃  ·  $leaves leaves',
            ),
          ),
        ),
        SizedBox(
          height: 40,
          child: water == 0
              ? TextButton(
                  onPressed: () => setState(() {
                    water = 1;
                    leaves = 3;
                  }),
                  child: const Text('Try again'),
                )
              : null,
        ),
      ],
    ),
  );
}

// Page 4: streak simulation (auto-plays)
class _StreakPane extends StatefulWidget {
  const _StreakPane();
  @override
  State<_StreakPane> createState() => _StreakPaneState();
}

class _StreakPaneState extends State<_StreakPane> {
  // 0 = seed, 1..6 = days completed, 7 = missed day (tree dies), 8 = hold
  int step = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 1100), (_) {
      if (mounted) setState(() => step = (step + 1) % 9);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _dot(int i) {
    final done = i < min(step, 6);
    final missed = i == 6 && step >= 7;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done
            ? forest
            : missed
            ? Colors.redAccent.withValues(alpha: 0.15)
            : Colors.white,
        border: Border.all(
          color: done
              ? forest
              : missed
              ? Colors.redAccent
              : sage,
          width: 1.5,
        ),
      ),
      child: done
          ? const Icon(Icons.check, color: Colors.white, size: 18)
          : missed
          ? const Icon(Icons.close, color: Colors.redAccent, size: 18)
          : Text(
              '${i + 1}',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dead = step >= 7;
    final leaves = step == 0 ? 0 : min(step, 6);
    String status;
    if (step == 0) {
      status = 'Day 1 starts with a seed 🌱';
    } else if (!dead) {
      status = 'Day $step: habit done  →  💧 +1  →  🍃 +1';
    } else {
      status = 'Day 7 missed: the tree died 🥀';
    }

    return _OnbFrame(
      title: 'Keep your streak alive',
      body: 'Finish your habit every day and your streak and tree grow. Miss a day and the tree dies, so a new seed starts from day 1.',
      child: Column(
        children: [
          Expanded(
            child: _MiniTree(leaves: leaves, alive: !dead),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [for (var i = 0; i < 7; i++) _dot(i)],
          ),
          const SizedBox(height: 12),
          _StatChip(
            dead ? '🥀' : '🔥',
            dead ? 'Streak lost' : '$leaves day streak  ·  🍃 $leaves',
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 20,
            child: Text(
              status,
              style: TextStyle(
                fontSize: 13,
                color: dead ? Colors.redAccent : forest,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Every habit keeps its own tree and streak. Switch anytime, your progress is saved.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.black45),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ───────────────────────── TIMER DIALOG ─────────────────────────

Future<bool?> showTimerDialog(
  BuildContext context,
  HabitDef h, {
  String? note,
}) {
  return showGeneralDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'Timer',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (_, __, ___) => _TimerDialog(def: h, note: note),
    transitionBuilder: (_, a, __, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(
        scale: Tween(begin: 0.95, end: 1.0).animate(a),
        child: child,
      ),
    ),
  );
}

class _TimerDialog extends StatefulWidget {
  final HabitDef def;
  final String? note;
  const _TimerDialog({required this.def, this.note});
  @override
  State<_TimerDialog> createState() => _TimerDialogState();
}

class _TimerDialogState extends State<_TimerDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(seconds: widget.def.timerSeconds),
  );
  bool started = false, finished = false;

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        HapticFeedback.heavyImpact();
        setState(() => finished = true);
        Future.delayed(const Duration(milliseconds: 1000), () {
          if (mounted) Navigator.pop(context, true);
        });
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _start() {
    setState(() => started = true);
    _c.forward(from: 0);
  }

  void _cancel() {
    _c.stop();
    Navigator.pop(context, false);
  }

  String _fmt(int secs) {
    final m = secs ~/ 60, s = secs % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.def.timerSeconds;
    return Material(
      type: MaterialType.transparency,
      child: Center(
        child: Container(
          width: 300,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: cream,
            borderRadius: BorderRadius.circular(32),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${widget.def.emoji}  ${widget.def.name}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: forest,
                ),
              ),
              const SizedBox(height: 18),
              AnimatedBuilder(
                animation: _c,
                builder: (_, __) {
                  final left = (total * (1 - _c.value)).ceil();
                  return SizedBox(
                    width: 170,
                    height: 170,
                    child: CustomPaint(
                      painter: _RingPainter(_c.value),
                      child: Center(
                        child: finished
                            ? const Text('🎉', style: TextStyle(fontSize: 56))
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _fmt(started ? left : total),
                                    style: const TextStyle(
                                      fontSize: 38,
                                      fontWeight: FontWeight.w800,
                                      color: forest,
                                    ),
                                  ),
                                  Text(
                                    started ? 'Breathe…' : 'Ready?',
                                    style: const TextStyle(
                                      color: Colors.black54,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 14),
              if (widget.note != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    widget.note!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.redAccent,
                    ),
                  ),
                ),
              if (finished)
                const Text(
                  'Done! Habit completed 🌿',
                  style: TextStyle(fontWeight: FontWeight.w700, color: forest),
                )
              else if (!started) ...[
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: forest,
                      shape: const StadiumBorder(),
                    ),
                    onPressed: _start,
                    child: const Text('Start timer'),
                  ),
                ),
                TextButton(onPressed: _cancel, child: const Text('Cancel')),
              ] else
                TextButton(onPressed: _cancel, child: const Text('Stop')),
              if (!finished && total < 60)
                const Text(
                  'Demo timer',
                  style: TextStyle(fontSize: 11, color: Colors.black38),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  _RingPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 8;
    final bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..color = sage.withValues(alpha: 0.3);
    final fg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..color = forest;
    canvas.drawCircle(c, r, bg);
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -pi / 2,
      2 * pi * progress,
      false,
      fg,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress;
}

// ───────────────────────── BOTTLE REWARD OVERLAY ─────────────────────────

/// Shows a big "+1 bottle of water" overlay: pops in with a splash,
/// then flies into the "Water tree" button.
void showBottleReward(BuildContext context, Offset target) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _BottleReward(target: target, onDone: () => entry.remove()),
  );
  overlay.insert(entry);
  HapticFeedback.mediumImpact();
}

class _BottleReward extends StatefulWidget {
  final Offset target;
  final VoidCallback onDone;
  const _BottleReward({required this.target, required this.onDone});
  @override
  State<_BottleReward> createState() => _BottleRewardState();
}

class _BottleRewardState extends State<_BottleReward>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  @override
  void initState() {
    super.initState();
    _c.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final center = Offset(size.width / 2, size.height * 0.42);

    return Material(
      type: MaterialType.transparency,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) {
            final t = _c.value;
            final pop = Curves.elasticOut.transform((t / 0.3).clamp(0.0, 1.0));
            final fly = Curves.easeInCubic.transform(
              ((t - 0.7) / 0.3).clamp(0.0, 1.0),
            );
            final pos = Offset.lerp(center, widget.target, fly)!;
            final scale = pop * (1 - 0.75 * fly);
            final fadeIn = (t / 0.12).clamp(0.0, 1.0);
            final fadeOut = fly > 0.8 ? (1 - fly) / 0.2 : 1.0;
            final backdrop = t < 0.12
                ? t / 0.12
                : (t > 0.7 ? 1 - (t - 0.7) / 0.3 : 1.0);

            return Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black.withValues(
                      alpha: 0.45 * backdrop.clamp(0.0, 1.0),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: _SplashPainter(center, (t / 0.5).clamp(0.0, 1.0)),
                  ),
                ),
                Positioned(
                  left: pos.dx - 110,
                  top: pos.dy - 80,
                  child: Opacity(
                    opacity: (fadeIn * fadeOut).clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: scale,
                      child: const _RewardCard(),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RewardCard extends StatelessWidget {
  const _RewardCard();
  @override
  Widget build(BuildContext context) => Container(
    width: 220,
    height: 160,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(32),
      boxShadow: const [
        BoxShadow(
          color: Color(0x40000000),
          blurRadius: 30,
          offset: Offset(0, 12),
        ),
      ],
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 62,
          height: 62,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF9BDCFF), Color(0xFF4A90E2)],
            ),
          ),
          child: const Text('💧', style: TextStyle(fontSize: 32)),
        ),
        const SizedBox(height: 8),
        const Text(
          '+1',
          style: TextStyle(
            fontSize: 34,
            height: 1,
            fontWeight: FontWeight.w900,
            color: forest,
          ),
        ),
        const SizedBox(height: 2),
        const Text(
          'bottle of water',
          style: TextStyle(fontSize: 14, color: Colors.black54),
        ),
      ],
    ),
  );
}

class _SplashPainter extends CustomPainter {
  final Offset center;
  final double p; // 0..1
  _SplashPainter(this.center, this.p);

  @override
  void paint(Canvas canvas, Size size) {
    if (p >= 1) return;
    const n = 16;
    final e = Curves.easeOut.transform(p);
    for (var i = 0; i < n; i++) {
      final a = i * 2 * pi / n + (i.isEven ? 0.0 : 0.2);
      final dist = 70 + (i.isEven ? 120 : 85) * e;
      final pos = center + Offset(cos(a), sin(a)) * dist;
      final r = (i.isEven ? 7.0 : 4.5) * (1 - p) + 1;
      canvas.drawCircle(
        pos,
        r,
        Paint()
          ..color =
              (i % 3 == 0 ? const Color(0xFFBDE6FF) : const Color(0xFF6DB6F5))
                  .withValues(alpha: (1 - p).clamp(0.0, 1.0)),
      );
    }
  }

  @override
  bool shouldRepaint(_SplashPainter old) => old.p != p;
}

// ───────────────────────── GARDEN ─────────────────────────

class _StatChip extends StatelessWidget {
  final String emoji, text;
  const _StatChip(this.emoji, this.text);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(20),
      boxShadow: softShadow,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(emoji, style: const TextStyle(fontSize: 15)),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(
            color: forest,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ],
    ),
  );
}

class GardenPage extends StatefulWidget {
  final AppState app;
  const GardenPage({super.key, required this.app});
  @override
  State<GardenPage> createState() => _GardenPageState();
}

class _GardenPageState extends State<GardenPage> with TickerProviderStateMixin {
  late final AnimationController _sway = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
  )..repeat();
  late final AnimationController _grow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    value: 1,
  );
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);
  final GlobalKey _waterKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.app.chosen == null) {
        showHabitDeck(context, widget.app);
      }
    });
  }

  @override
  void dispose() {
    _sway.dispose();
    _grow.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void _showReward() {
    final box = _waterKey.currentContext?.findRenderObject() as RenderBox?;
    final size = MediaQuery.of(context).size;
    final target = (box != null && box.attached)
        ? box.localToGlobal(box.size.center(Offset.zero))
        : Offset(size.width / 2, size.height * 0.85);
    showBottleReward(context, target);
  }

  void _afterComplete() {
    widget.app.completeToday();
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showReward();
    });
  }

  Future<void> _onCardTap() async {
    final app = widget.app;

    if (app.chosen == null) {
      showHabitDeck(context, app);
      return;
    }
    final h = app.chosenDef!;

    if (app.doneToday) {
      final undo = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: cream,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          title: Text('${h.emoji}  Done for today 🌿'),
          content: const Text('Come back tomorrow to earn more water.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Undo today'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: forest),
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      if (undo == true) app.undoToday();
      return;
    }

    // Timer habits (e.g. meditation): finishing the timer = habit done
    if (h.timerSeconds > 0) {
      final ok = await showTimerDialog(
        context,
        h,
        note: app.dead
            ? 'Your tree died. Finishing plants a new seed 🌱'
            : null,
      );
      if (ok == true) _afterComplete();
      return;
    }

    final dead = app.dead;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: Text(dead ? 'Your tree died 🥀' : '${h.emoji}  ${h.name}'),
        content: Text(
          dead
              ? 'You missed a day. Confirming today plants a new seed and starts again at day 1.'
              : 'Did you complete this habit today?\nConfirming gives you 1 bottle of water 💧',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: forest),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(dead ? 'Plant new seed 🌱' : 'Yes, I did it!'),
          ),
        ],
      ),
    );
    if (ok == true) _afterComplete();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final h = app.chosenDef;
    final canWater = app.water > 0 && !app.dead;

    String subtitle;
    if (h == null) {
      subtitle = 'Tap to pick your first habit';
    } else if (app.dead) {
      subtitle = 'Your tree died 🥀 Tap to plant a new seed';
    } else if (app.doneToday) {
      subtitle = 'Done today ✓';
    } else if (h.timerSeconds > 0) {
      subtitle = 'Tap to start the timer ⏱';
    } else {
      subtitle = 'Tap to confirm today';
    }

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFBF8F0), Color(0xFFE3ECDA)],
        ),
      ),
      child: Column(
        children: [
          // Stat chips
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _StatChip('🔥', '${app.streak}'),
                const SizedBox(width: 8),
                _StatChip('💧', '${app.water}'),
                const SizedBox(width: 8),
                _StatChip('🍃', '${app.leaves}'),
              ],
            ),
          ),
          // Habit card
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                boxShadow: softShadow,
              ),
              child: Material(
                color: app.doneToday ? const Color(0xFFDCE7D8) : Colors.white,
                borderRadius: BorderRadius.circular(26),
                child: InkWell(
                  borderRadius: BorderRadius.circular(26),
                  onTap: _onCardTap,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: sage.withValues(alpha: 0.25),
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            h?.emoji ?? '🌱',
                            style: const TextStyle(fontSize: 28),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                h?.name ?? 'Choose a habit',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (app.doneToday)
                          const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.check_circle,
                              color: forest,
                              size: 28,
                            ),
                          ),
                        IconButton.filledTonal(
                          tooltip: 'Change habit',
                          onPressed: () => showHabitDeck(context, app),
                          icon: const Icon(Icons.swap_horiz),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Tree
          Expanded(
            child: AnimatedBuilder(
              animation: Listenable.merge([_sway, _grow]),
              builder: (_, __) => CustomPaint(
                size: Size.infinite,
                painter: TreePainter(
                  leaves: app.leaves,
                  streak: app.streak,
                  alive: !app.dead,
                  t: _sway.value,
                  grow: Curves.easeOutBack.transform(_grow.value),
                ),
              ),
            ),
          ),
          // Water button
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (_, child) => Transform.scale(
                scale: canWater ? 1 + 0.035 * _pulse.value : 1,
                child: child,
              ),
              child: SizedBox(
                key: _waterKey,
                width: double.infinity,
                height: 54,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF3F8EDB),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.black12,
                    shape: const StadiumBorder(),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  onPressed: canWater
                      ? () {
                          if (app.waterTree()) {
                            HapticFeedback.lightImpact();
                            _grow.forward(from: 0);
                          }
                        }
                      : null,
                  icon: const Icon(Icons.water_drop),
                  label: Text(
                    canWater
                        ? 'Water tree  ·  ${app.water} 💧'
                        : 'Complete your habit to earn water',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── SWIPE DECK ─────────────────────────

Future<void> showHabitDeck(BuildContext context, AppState app) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (_, __, ___) => HabitDeck(app: app),
    transitionBuilder: (_, a, __, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(
        scale: Tween(begin: 0.95, end: 1.0).animate(a),
        child: child,
      ),
    ),
  );
}

class HabitDeck extends StatefulWidget {
  final AppState app;
  const HabitDeck({super.key, required this.app});
  @override
  State<HabitDeck> createState() => _HabitDeckState();
}

class _HabitDeckState extends State<HabitDeck>
    with SingleTickerProviderStateMixin {
  late List<HabitDef> cards;
  Offset drag = Offset.zero;
  Offset _from = Offset.zero, _to = Offset.zero;
  VoidCallback? _onDone;
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void initState() {
    super.initState();
    cards =
        widget.app.library.where((h) => h.name != widget.app.chosen).toList()
          ..shuffle();
    if (cards.length > 4) cards = cards.sublist(0, 4);
    _c.addListener(() {
      if (!mounted) return;
      setState(
        () =>
            drag = Offset.lerp(_from, _to, Curves.easeOut.transform(_c.value))!,
      );
    });
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        final d = _onDone;
        _onDone = null;
        d?.call();
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _animateTo(Offset to, VoidCallback? done) {
    _from = drag;
    _to = to;
    _onDone = done;
    _c.forward(from: 0);
  }

  void _swipe(bool right) {
    if (_c.isAnimating || cards.isEmpty) return;
    final def = cards.first;
    _animateTo(Offset(right ? 600 : -600, 0), () {
      if (right) {
        widget.app.chooseHabit(def);
        Navigator.pop(context);
      } else {
        setState(() {
          cards.add(cards.removeAt(0));
          drag = Offset.zero;
        });
      }
    });
  }

  Future<void> _createOwn() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Create your own habit'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. Stretch 5 minutes'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('Choose'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && !name.contains('|')) {
      final def = widget.app.addCustom(name);
      widget.app.chooseHabit(def);
      if (mounted) Navigator.pop(context);
    }
  }

  Widget _cardAt(int i, double w, double h) {
    final card = _HabitCard(def: cards[i], width: w, height: h);
    if (i != 0) {
      return Transform.translate(
        offset: Offset(0, 14.0 * i),
        child: Transform.scale(scale: 1 - 0.05 * i, child: card),
      );
    }
    final chooseOpacity = (drag.dx / 100).clamp(0.0, 1.0);
    final skipOpacity = (-drag.dx / 100).clamp(0.0, 1.0);
    return GestureDetector(
      onPanUpdate: (d) {
        if (_c.isAnimating) return;
        setState(() => drag += d.delta);
      },
      onPanEnd: (_) {
        if (_c.isAnimating) return;
        if (drag.dx > 110) {
          _swipe(true);
        } else if (drag.dx < -110) {
          _swipe(false);
        } else {
          _animateTo(Offset.zero, null);
        }
      },
      child: Transform.translate(
        offset: drag,
        child: Transform.rotate(
          angle: drag.dx / 700,
          child: Stack(
            children: [
              card,
              Positioned(
                top: 24,
                left: 20,
                child: Opacity(
                  opacity: chooseOpacity,
                  child: const _Stamp(text: 'CHOOSE', color: forest),
                ),
              ),
              Positioned(
                top: 24,
                right: 20,
                child: Opacity(
                  opacity: skipOpacity,
                  child: const _Stamp(text: 'SKIP', color: Colors.redAccent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final w = min(size.width - 56, 340.0);
    final h = min(size.height * 0.5, 420.0);
    final n = min(cards.length, 3);

    return Material(
      color: Colors.transparent,
      child: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            const Text(
              'Choose your habit',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Swipe right to choose  ·  left to skip',
              style: TextStyle(color: Colors.white70),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Every habit keeps its own tree 🌳 progress is saved',
                style: TextStyle(color: Colors.amberAccent, fontSize: 12),
              ),
            ),
            Expanded(
              child: Center(
                child: SizedBox(
                  width: w,
                  height: h + 30,
                  child: Stack(
                    alignment: Alignment.topCenter,
                    clipBehavior: Clip.none,
                    children: [
                      for (var i = n - 1; i >= 0; i--) _cardAt(i, w, h),
                    ],
                  ),
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _RoundBtn(
                  icon: Icons.close,
                  color: Colors.redAccent,
                  onTap: () => _swipe(false),
                ),
                const SizedBox(width: 40),
                _RoundBtn(
                  icon: Icons.check,
                  color: forest,
                  onTap: () => _swipe(true),
                ),
              ],
            ),
            TextButton(
              onPressed: _createOwn,
              child: const Text(
                '+ Create your own',
                style: TextStyle(color: Colors.white),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _HabitCard extends StatelessWidget {
  final HabitDef def;
  final double width, height;
  const _HabitCard({
    required this.def,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: cream,
      borderRadius: BorderRadius.circular(28),
      boxShadow: const [
        BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(0, 8)),
      ],
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(def.emoji, style: const TextStyle(fontSize: 84)),
        const SizedBox(height: 20),
        Text(
          def.name,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: forest,
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'IDENTITY',
          style: TextStyle(
            letterSpacing: 2,
            fontSize: 11,
            color: Colors.black45,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          def.identity,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 15,
            fontStyle: FontStyle.italic,
            color: Colors.black87,
          ),
        ),
        if (def.timerSeconds > 0) ...[
          const SizedBox(height: 14),
          const Text(
            '⏱ Timer habit',
            style: TextStyle(color: forest, fontWeight: FontWeight.w700),
          ),
        ],
      ],
    ),
  );
}

class _Stamp extends StatelessWidget {
  final String text;
  final Color color;
  const _Stamp({required this.text, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      border: Border.all(color: color, width: 3),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 20),
    ),
  );
}

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _RoundBtn({
    required this.icon,
    required this.color,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: const CircleBorder(),
    elevation: 4,
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Icon(icon, color: color, size: 30),
      ),
    ),
  );
}

// ───────────────────────── HABITS (library) ─────────────────────────

class HabitsPage extends StatelessWidget {
  final AppState app;
  const HabitsPage({super.key, required this.app});

  Future<void> _addCustom(BuildContext context) async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('New habit'),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && !name.contains('|')) {
      app.addCustom(name);
    }
  }

  Widget? _trailing(HabitDef h) {
    if (h.name == app.chosen) {
      return const Icon(Icons.check_circle, color: forest);
    }
    final lv = app.leavesFor(h.name);
    if (app.deadFor(h.name)) {
      return Text('🥀 $lv🍃', style: const TextStyle(fontSize: 12));
    }
    if (lv > 0) {
      return Text(
        '🔥${app.streakFor(h.name)} · 🍃$lv',
        style: const TextStyle(fontSize: 12, color: forest),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        backgroundColor: forest,
        foregroundColor: Colors.white,
        onPressed: () => _addCustom(context),
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
        children: [
          const Text(
            'Habits',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: forest,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'Tap to switch. Each habit keeps its own tree and streak. Long-press a custom habit to delete.',
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 14),
          for (final h in app.library)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: softShadow,
                ),
                child: Material(
                  color: h.name == app.chosen
                      ? const Color(0xFFDCE7D8)
                      : Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22),
                    side: h.name == app.chosen
                        ? const BorderSide(color: forest, width: 1.5)
                        : BorderSide.none,
                  ),
                  child: ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    leading: Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: sage.withValues(alpha: 0.22),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        h.emoji,
                        style: const TextStyle(fontSize: 24),
                      ),
                    ),
                    title: Text(
                      h.timerSeconds > 0 ? '${h.name}  ⏱' : h.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      h.identity,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: _trailing(h),
                    onTap: () => app.chooseHabit(h),
                    onLongPress: () => app.removeCustom(h.name),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ───────────────────────── ACTIVITIES ─────────────────────────

class ActivitiesPage extends StatelessWidget {
  final AppState app;
  const ActivitiesPage({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final entries = List.of(app.log)..sort((a, b) => b.compareTo(a));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Activities',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: forest,
          ),
        ),
        const SizedBox(height: 2),
        const Text(
          'Every day you confirmed a habit.',
          style: TextStyle(color: Colors.black54),
        ),
        const SizedBox(height: 14),
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(child: Text('Nothing yet 🌱')),
          ),
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: softShadow,
              ),
              child: ListTile(
                leading: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: sage.withValues(alpha: 0.25),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.eco, color: forest),
                ),
                title: Text(
                  e.substring(e.indexOf('|') + 1),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(e.substring(0, e.indexOf('|'))),
                trailing: const Text('💧', style: TextStyle(fontSize: 18)),
              ),
            ),
          ),
      ],
    );
  }
}

// ───────────────────────── SETTINGS ─────────────────────────

class _StatTile extends StatelessWidget {
  final String emoji, value, label;
  const _StatTile(this.emoji, this.value, this.label);
  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 26)),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: forest,
            ),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ],
      ),
    ),
  );
}

class SettingsPage extends StatelessWidget {
  final AppState app;
  const SettingsPage({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Settings',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: forest,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _StatTile('🍃', '${app.leaves}', 'Leaves on tree'),
            const SizedBox(width: 12),
            _StatTile('💧', '${app.water}', 'Bottles of water'),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _StatTile('🔥', '${app.streak}', 'Day streak'),
            const SizedBox(width: 12),
            _StatTile('✅', '${app.log.length}', 'Total days done'),
          ],
        ),
        const SizedBox(height: 16),

        // ── DEMO: time travel (for showing the teacher) ──
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFFFF4D6),
            borderRadius: BorderRadius.circular(22),
            boxShadow: softShadow,
          ),
          child: Column(
            children: [
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                ),
                leading: const Icon(Icons.fast_forward, color: forest),
                title: const Text('Demo: next day'),
                subtitle: Text(
                  debugDayOffset == 0
                      ? 'Today is the real date'
                      : 'App date: +$debugDayOffset day(s) ahead',
                ),
                onTap: () => app.debugSkipDays(1),
              ),
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                ),
                leading: const Icon(Icons.skip_next, color: Colors.redAccent),
                title: const Text('Demo: skip 2 days'),
                subtitle: const Text('Miss a day: the tree dies 🥀'),
                onTap: () => app.debugSkipDays(2),
              ),
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                ),
                leading: const Icon(Icons.restore),
                title: const Text('Demo: reset time'),
                subtitle: const Text('Go back to the real date'),
                onTap: app.debugResetTime,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            boxShadow: softShadow,
          ),
          child: ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
            leading: const Icon(Icons.play_circle_outline, color: forest),
            title: const Text('Replay intro'),
            subtitle: const Text('See how GrowUp works again'),
            onTap: app.replayOnboarding,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            boxShadow: softShadow,
          ),
          child: ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
            leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
            title: const Text('Reset history'),
            subtitle: const Text('Deletes every tree and starts from a seed'),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: cream,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                  title: const Text('Are you sure?'),
                  content: const Text(
                    'All your trees, streaks and history will be deleted.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Reset'),
                    ),
                  ],
                ),
              );
              if (ok == true) app.resetHistory();
            },
          ),
        ),
        const SizedBox(height: 24),
        const Center(
          child: Text('GrowUp v1.5', style: TextStyle(color: Colors.black38)),
        ),
      ],
    );
  }
}

// ───────────────────────── TREE ─────────────────────────

class _Branch {
  final Offset a, b;
  final double w;
  final int depth;
  _Branch(this.a, this.b, this.w, this.depth);
}

class TreePainter extends CustomPainter {
  final int leaves, streak;
  final bool alive;
  final double t, grow;
  TreePainter({
    required this.leaves,
    required this.streak,
    required this.alive,
    required this.t,
    required this.grow,
  });

  static const maxDepth = 5;

  List<_Branch> _build(Size size) {
    final rnd = Random(7);
    final out = <_Branch>[];
    void growBranch(Offset p, double ang, double len, double w, int d) {
      if (d > maxDepth) return;
      final e = p + Offset(sin(ang), -cos(ang)) * len;
      out.add(_Branch(p, e, w, d));
      growBranch(
        e,
        ang - 0.35 - rnd.nextDouble() * 0.3,
        len * 0.78,
        w * 0.68,
        d + 1,
      );
      growBranch(
        e,
        ang + 0.35 + rnd.nextDouble() * 0.3,
        len * 0.78,
        w * 0.68,
        d + 1,
      );
    }

    growBranch(
      Offset(size.width / 2, size.height * 0.95),
      0,
      size.height * 0.24,
      size.height * 0.035,
      0,
    );
    out.sort((x, y) => x.depth.compareTo(y.depth));
    return out;
  }

  void _cloud(Canvas canvas, Offset c, double s) {
    final p = Paint()..color = Colors.white.withValues(alpha: 0.75);
    canvas.drawCircle(c, s, p);
    canvas.drawCircle(c + Offset(s * 0.9, s * 0.2), s * 0.75, p);
    canvas.drawCircle(c + Offset(-s * 0.9, s * 0.25), s * 0.65, p);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: c + Offset(0, s * 0.55),
          width: s * 3,
          height: s * 0.9,
        ),
        Radius.circular(s * 0.45),
      ),
      p,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Sky decorations: sun + drifting clouds
    if (alive) {
      final sc = Offset(size.width * 0.84, size.height * 0.12);
      final glowR = size.width * 0.14;
      canvas.drawCircle(
        sc,
        glowR,
        Paint()
          ..shader = const RadialGradient(
            colors: [Color(0x80FFE08A), Color(0x00FFE08A)],
          ).createShader(Rect.fromCircle(center: sc, radius: glowR)),
      );
      canvas.drawCircle(
        sc,
        size.width * 0.045,
        Paint()..color = const Color(0xFFFFD66B),
      );
    }
    _cloud(
      canvas,
      Offset(size.width * (0.2 + 0.04 * sin(t * 2 * pi)), size.height * 0.16),
      size.width * 0.04,
    );
    _cloud(
      canvas,
      Offset(size.width * (0.62 - 0.03 * sin(t * 2 * pi)), size.height * 0.07),
      size.width * 0.03,
    );

    // Ground
    final gc = Offset(size.width / 2, size.height * 0.96);
    canvas.drawOval(
      Rect.fromCenter(
        center: gc,
        width: size.width * 0.8,
        height: size.height * 0.13,
      ),
      Paint()..color = sage.withValues(alpha: 0.35),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: gc,
        width: size.width * 0.55,
        height: size.height * 0.085,
      ),
      Paint()..color = sage.withValues(alpha: 0.6),
    );

    final branches = _build(size);
    final visibleDepth = min(maxDepth, 1 + leaves ~/ 4);
    final trunk = Paint()
      ..color = alive ? const Color(0xFF7A5C45) : const Color(0xFF6E6862)
      ..strokeCap = StrokeCap.round;

    for (final b in branches) {
      if (b.depth > visibleDepth) continue;
      trunk.strokeWidth = max(1.5, b.w);
      canvas.drawLine(b.a, b.b, trunk);
    }

    final rnd = Random(3);
    var idx = 0;
    for (final b in branches) {
      if (b.depth == 0) continue;
      for (final f in [0.65, 1.0]) {
        final pos = Offset.lerp(b.a, b.b, f)!;
        final side = rnd.nextBool() ? 1 : -1;
        final base = rnd.nextDouble();
        final myIdx = idx++;
        if (myIdx >= leaves || b.depth > visibleDepth) continue;
        final color = alive
            ? Color.lerp(const Color(0xFF9CCB86), forest, base)!
            : Color.lerp(
                const Color(0xFFB59B5B),
                const Color(0xFF7A6A55),
                base,
              )!;
        final sway = alive ? sin(t * 2 * pi + myIdx) * 0.12 : 0.0;
        final angle = side * (alive ? 0.6 + base : 1.5 + base) + sway;
        final scale = myIdx == leaves - 1 ? grow : 1.0;
        _leaf(canvas, pos, size.height * 0.08 * scale, angle, color);
      }
    }

    if (alive && streak >= 7 && leaves > 40) {
      final flower = Paint()..color = const Color(0xFFF4A6B7);
      for (final b in branches.where((b) => b.depth == maxDepth)) {
        canvas.drawCircle(b.b, 4, flower);
      }
    }
  }

  void _leaf(Canvas c, Offset p, double len, double ang, Color color) {
    c.save();
    c.translate(p.dx, p.dy);
    c.rotate(ang);
    final path = Path()
      ..moveTo(0, 0)
      ..quadraticBezierTo(len * 0.7, -len * 0.4, 0, -len)
      ..quadraticBezierTo(-len * 0.7, -len * 0.4, 0, 0);
    c.drawPath(path, Paint()..color = color);
    c.restore();
  }

  @override
  bool shouldRepaint(TreePainter old) => true;
}
