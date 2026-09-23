import 'package:flutter/material.dart';

import 'user_session_controller.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.session});
  final UserSessionController session;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Framebase')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: AnimatedBuilder(
          animation: widget.session,
          builder: (context, _) {
            final state = widget.session.state;
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (state == SessionState.loading ||
                      state == SessionState.resolving) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 16),
                    const Text('Loading your library…'),
                  ] else if (state == SessionState.denied ||
                      state == SessionState.error) ...[
                    Text(widget.session.message),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: widget.session.retry,
                      child: const Text('Retry'),
                    ),
                    TextButton(
                      onPressed: widget.session.signOut,
                      child: const Text('Sign out'),
                    ),
                  ] else ...[
                    const Text(
                      'Sign in to your street library',
                      style: TextStyle(fontSize: 22),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      key: const Key('email'),
                      controller: email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                    TextField(
                      key: const Key('password'),
                      controller: password,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Password'),
                    ),
                    if (widget.session.message.isNotEmpty)
                      Text(widget.session.message),
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const Key('sign_in'),
                      onPressed: widget.session.signingIn
                          ? null
                          : () => widget.session.signIn(
                              email.text,
                              password.text,
                            ),
                      child: Text(
                        widget.session.signingIn ? 'Signing in…' : 'Sign in',
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Offline example: configure a fake account to try the signed-in flow.',
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
}

class ProfileSheet extends StatelessWidget {
  const ProfileSheet({super.key, required this.session});
  final UserSessionController session;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            session.user?.displayName ?? 'Account',
            style: const TextStyle(fontSize: 22),
          ),
          const SizedBox(height: 12),
          Text(
            session.state == SessionState.ready
                ? 'VMODAL connected'
                : 'VMODAL unavailable',
          ),
          Text('Library: ${session.canRead ? 'read' : 'unavailable'}'),
          Text(
            'Upload and prepare: ${session.canWrite ? 'allowed' : 'unavailable'}',
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('sign_out'),
            onPressed: () {
              Navigator.pop(context);
              session.signOut();
            },
            child: const Text('Sign out'),
          ),
        ],
      ),
    ),
  );
}
