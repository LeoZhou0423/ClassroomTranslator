"""Use Cocoa save panels on the UI thread; never write to an empty URL."""

import sys
import threading
from pathlib import Path


def choose_export(window, webview, filename, format):
    if sys.platform != "darwin":
        paths = window.create_file_dialog(
            webview.FileDialog.SAVE,
            directory=str(Path.home()),
            save_filename=filename,
            file_types=(("Word Document (*.docx)" if format == "docx" else "Text File (*.txt)"),),
        )
        if not paths:
            return None
        raw = paths[0] if isinstance(paths, (list, tuple)) else paths
    else:
        from AppKit import NSModalResponseOK, NSSavePanel
        from Foundation import NSURL
        from PyObjCTools import AppHelper

        finished = threading.Event()
        result = {}

        def show():
            try:
                panel = NSSavePanel.savePanel()
                panel.setNameFieldStringValue_(filename)
                panel.setDirectoryURL_(NSURL.fileURLWithPath_(str(Path.home() / "Documents")))
                panel.setCanCreateDirectories_(True)
                panel.setAllowedFileTypes_([format])
                panel.setAllowsOtherFileTypes_(False)
                if panel.runModal() == NSModalResponseOK:
                    url = panel.URL()
                    result["path"] = str(url.path()) if url else ""
            except Exception:
                result["error"] = True
            finally:
                finished.set()

        AppHelper.callAfter(show)
        finished.wait()
        if result.get("error"):
            raise ValueError("无法打开保存窗口，请重试")
        raw = result.get("path")
        if raw is None:
            return None
    raw = str(raw or "").strip()
    if not raw:
        raise ValueError("保存位置为空，请重新选择位置")
    path = Path(raw).expanduser()
    if not path.is_absolute():
        raise ValueError("保存位置无效，请选择完整路径")
    return path if path.suffix.lower() == "." + format else path.with_suffix("." + format)
