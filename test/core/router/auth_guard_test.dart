import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vpn_app/core/router/guards/auth_guard.dart';

void main() {
  late _GoRouterState state;

  setUp(() {
    state = _GoRouterState();
  });

  test('restoring session stays on gate instead of showing login', () {
    when(() => state.matchedLocation).thenReturn('/gate');

    expect(
      AuthGuard.redirect(
        isSessionRestoring: true,
        isAuthenticated: false,
        state: state,
      ),
      isNull,
    );
  });

  test('restoring session sends other locations back to gate', () {
    when(() => state.matchedLocation).thenReturn('/login');

    expect(
      AuthGuard.redirect(
        isSessionRestoring: true,
        isAuthenticated: false,
        state: state,
      ),
      '/gate',
    );
  });

  test('restored gate routes signed-in sessions directly home', () {
    when(() => state.matchedLocation).thenReturn('/gate');

    expect(
      AuthGuard.redirect(
        isSessionRestoring: false,
        isAuthenticated: true,
        state: state,
      ),
      '/vpn',
    );
  });

  test('restored gate routes signed-out sessions to login', () {
    when(() => state.matchedLocation).thenReturn('/gate');

    expect(
      AuthGuard.redirect(
        isSessionRestoring: false,
        isAuthenticated: false,
        state: state,
      ),
      '/login',
    );
  });
}

class _GoRouterState extends Mock implements GoRouterState {}
