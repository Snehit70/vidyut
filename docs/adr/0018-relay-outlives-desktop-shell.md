# Relay outlives the desktop shell

> Status: accepted

The Relay is a session service, not a window. Closing the desktop shell, or
Quit on the tray, must not stop clipboard sync or transfers. Stop relay is an
explicit action. On Linux that service is a systemd user unit; on Windows it
will be a service or autostart task with the same rule.

We rejected embedding the Relay in Electron or in the tray process. Either
makes copy/paste depend on a UI process staying alive, which is the opposite
of a clipboard pool.
