"""Launch LingoClass in a native platform WebView."""
import sys
if getattr(sys, 'frozen', False):
    from pathlib import Path
    import os
    log_dir=Path(os.getenv('LOCALAPPDATA',str(Path.home()))) / 'LingoClass'
    log_dir.mkdir(parents=True,exist_ok=True)
    sys.stdout=sys.stderr=open(log_dir/'desktop.log','a',encoding='utf-8',buffering=1)
if sys.platform == 'win32':
    import ctypes
    # Keep this app separate from Python's shared taskbar group/icon cache.
    ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID('LingoClass.Desktop')
try:
    from asr_lab import main
except Exception:
    import traceback
    traceback.print_exc()
    raise

if __name__ == "__main__":
    if getattr(sys, 'frozen', False):
        from pathlib import Path
        import os
        log_dir=Path(os.getenv('LOCALAPPDATA',str(Path.home()))) / 'LingoClass'
        log_dir.mkdir(parents=True,exist_ok=True)
        sys.stdout=sys.stderr=open(log_dir/'desktop.log','a',encoding='utf-8',buffering=1)
        if '--port' not in sys.argv:
            import socket
            with socket.socket() as listener:
                listener.bind(('127.0.0.1',0))
                sys.argv.extend(['--port',str(listener.getsockname()[1])])
    sys.argv = [sys.argv[0], "--desktop", *sys.argv[1:]]
    main()
