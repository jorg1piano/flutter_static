# flutter_static_story

Pure Flutter story primitives and generic composition widgets for Flutter Static.

This package is intended to be safe for application repositories to depend on
from their `story/` files. It has no Studio app, terminal, speech, pty, macOS
runner, or Flutter plugin dependencies beyond Flutter itself.

Use this when you want app-specific stories to live beside app source code while
keeping the standalone macOS Studio/tooling independent of the app.
