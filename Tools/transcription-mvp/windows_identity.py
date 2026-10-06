"""Give Python-hosted and packaged windows the same taskbar identity."""
import sys
import subprocess
from pathlib import Path


def apply_window_identity(hwnd):
    if sys.platform != 'win32': return
    from win32com.propsys import propsys, pscon
    from app_paths import ICON_PATH
    command=[sys.executable]
    if not getattr(sys,'frozen',False):
        command.append(str(Path(__file__).with_name('desktop_app.py')))
    store=propsys.SHGetPropertyStoreForWindow(int(hwnd))
    for key,value in (
        (pscon.PKEY_AppUserModel_RelaunchCommand,subprocess.list2cmdline(command)),
        (pscon.PKEY_AppUserModel_RelaunchDisplayNameResource,'LingoClass'),
        (pscon.PKEY_AppUserModel_RelaunchIconResource,str(ICON_PATH)+',0'),
        (pscon.PKEY_AppUserModel_ID,'LingoClass.Desktop'),
    ):
        store.SetValue(key,propsys.PROPVARIANTType(value))
    store.Commit()


def apply_to_window(window):
    if sys.platform=='win32':
        apply_window_identity(window.native.Handle.ToInt64())
