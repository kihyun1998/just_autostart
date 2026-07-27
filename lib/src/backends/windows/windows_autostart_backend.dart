import '../../autostart_backend.dart';
import '../../exceptions.dart';

/// The Windows backend, which owns the **choice** of mechanism rather than any
/// mechanism itself.
///
/// Windows has two ways to start a program at login and they are stored in
/// completely separate places — a registry value and a scheduled task — so
/// neither can see the other, and both can be registered at once. That is not
/// hypothetical: an application that shipped through the `Run` key and later
/// switches to Task Scheduler leaves the old registration behind, and the user
/// gets the program **twice** at every login, with the console window still
/// appearing. Which was the reason for switching.
///
/// This exists to converge the machine on one of them.
///
/// **What it converges is bounded by the ownership guard, and that bound is
/// real.** Cleanup removes a registration only when the stored path names the
/// *configured* executable, because the alternative — matching on the name the
/// caller chose — would delete a third party's autostart out of a shared
/// namespace. So a registration an **earlier version wrote at a different
/// install path** is not removed: it is not distinguishable, from here, from
/// somebody else's. An application that installs into a versioned directory
/// therefore still has to remove its own old registration at uninstall time,
/// and this class does not do it for them. That is the same cost `disable()`
/// already carries on a single mechanism, and the safe direction to fail.
final class WindowsAutostartBackend implements AutostartBackend {
  /// Wraps the [chosen] mechanism, converging away from [other].
  const WindowsAutostartBackend({required this.chosen, required this.other});

  /// The mechanism the calling application asked for.
  final AutostartBackend chosen;

  /// The mechanism it did **not** ask for, which is only ever cleaned up.
  final AutostartBackend other;

  /// Registers through [chosen], then removes any registration [other] holds.
  ///
  /// **Neither order is safe in every case, and this one is chosen for what it
  /// ends on.** Registering first means a cleanup failure leaves the program
  /// launching twice — with autostart working. Cleaning first means a
  /// registration failure leaves the program launching *not at all*, with the
  /// old registration already destroyed. Both raise; the difference is the
  /// state left behind, and "the thing the caller asked for is on" is the one
  /// worth keeping. The cost is real: where the other mechanism's store is
  /// unwritable — a locked-down profile, a policy — this turns a working single
  /// registration into a double one that retrying cannot fix.
  ///
  /// A cleanup failure is raised as [MechanismCleanupException], **not** as the
  /// underlying failure. A caller that cannot tell it from "enable failed"
  /// would reasonably not save the user's preference and report that autostart
  /// is off — while it is on.
  ///
  /// Cleanup is [AutostartBackend.disable] on the other mechanism, and not a
  /// second implementation of the same idea. `disable()` already removes only
  /// registrations whose stored path names the configured executable — the
  /// ownership guard this ticket needs — so reusing it keeps one guard rather
  /// than two that can drift apart. It is also why cleanup is silent when the
  /// other mechanism holds nothing: `disable()` is idempotent.
  @override
  Future<void> enable() async {
    await chosen.enable();

    try {
      await other.disable();
    } on AutostartException catch (error) {
      throw MechanismCleanupException(error);
    }
  }

  /// Removes the registration from **both** mechanisms.
  ///
  /// Cleaning only the chosen one would make `disable()` a lie in the same
  /// upgrade this class exists for: a caller configured for Task Scheduler
  /// would switch autostart "off" while a `Run` key entry from an earlier
  /// version kept launching the program at every login. "Off" has to mean off.
  ///
  /// The cost is that a caller who only ever uses one mechanism still pays for
  /// reading the other here. That is deliberate: `disable()` is a rare,
  /// deliberate user action, where [isEnabled] may run on every start — so the
  /// expensive honesty is spent where it is affordable.
  ///
  /// **Both are attempted even when the first fails.** Stopping at the first
  /// failure would leave the other mechanism launching the program while
  /// `disable()` had already reported an error the caller may well treat as
  /// "nothing happened" — and which of the two stores is unreachable is not
  /// something this class gets to choose. The first failure is raised once both
  /// have been tried.
  @override
  Future<void> disable() async {
    AutostartException? failure;

    for (final backend in [chosen, other]) {
      try {
        await backend.disable();
      } on AutostartException catch (error) {
        failure ??= error;
      }
    }

    if (failure != null) throw failure;
  }

  /// Whether the program will launch through the **chosen** mechanism.
  ///
  /// Deliberately not an answer about both. Probing the other mechanism on
  /// every call would mean a caller configured for the registry `Run` key
  /// connects to the Task Scheduler service to answer a question about a
  /// registry value — and would then fail, rather than report `false`, on a
  /// machine where that service is unavailable.
  ///
  /// So this can differ from "will the program launch": a registration made by
  /// an **earlier version** through the other mechanism reads as `false` here
  /// while the program still starts. Calling [enable] or [disable] ends that —
  /// but only for a registration naming the same executable, per the bound on
  /// the class above. One written at an older install path outlives both, and
  /// no answer this package can give would be better than saying so.
  @override
  Future<bool> isEnabled() => chosen.isEnabled();
}
