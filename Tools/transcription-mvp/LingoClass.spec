from pathlib import Path
import sys
from PyInstaller.utils.hooks import collect_all, collect_data_files, collect_submodules

# CPython 3.12.0 corrupts inlined-comprehension locals when code.replace()
# rewrites code objects. Preserve filenames on that interpreter only.
if sys.version_info[:3] == (3,12,0):
    import PyInstaller.archive.writers as archive_writers
    import PyInstaller.building.utils as building_utils
    archive_writers.replace_filename_in_code_object = lambda code, filename: code
    building_utils.replace_filename_in_code_object = lambda code, filename: code

root = Path(SPECPATH).resolve()
project = root.parent.parent
datas = [(str(project/'Desktop'/'dist'),'Desktop/dist'),
         (str(project/'Desktop'/'public'/'app-icon.ico'),'Desktop/public'),
         (str(root/'asr_lab.html'),'.')]
# Provider credentials ship as an AES-256-GCM ciphertext sealed by
# encrypt_secrets.py. The passphrase lives in secrets_shares.py as masked
# Shamir shares, so no plaintext key is ever written into the build output.
for name in ('secrets_crypto.py','secrets_shares.py','secrets_store.py','encrypt_secrets.py'):
    datas.append((str(root/name),'.'))
secrets_document = root/'secrets'/'keys.enc.json'
if secrets_document.is_file():
    datas.append((str(secrets_document),'secrets'))
else:
    raise SystemExit('secrets/keys.enc.json is missing; run: python encrypt_secrets.py --mimo <key>')
datas.append((str(project/'Tools'/'speaker'/'models'/'campplus_zh_en_advanced.onnx'),'models/speaker'))
datas.append((str(root/'models'/'denoise'/'gtcrn_simple.onnx'),'models/denoise'))
for path in (project/'Tools'/'train'/'role-cls-onnx').glob('*'):
    if path.is_file():datas.append((str(path),'models/role'))
for name in ('whisper-small','whisper-tiny','whisper-small.en','grammar-t5'):
    for path in (root/'models'/name).glob('*'):
        if path.is_file() and not path.name.endswith('.part'):
            datas.append((str(path),'models/'+name))
binaries=[]
hiddenimports=[('keyring.backends.macOS' if sys.platform=='darwin' else 'keyring.backends.Windows'),'transformers.models.t5.modeling_t5',
               'transformers.models.t5.tokenization_t5','transformers.models.t5.tokenization_t5_fast','cryptography','requests']
for package in ('sherpa_onnx','webview','sounddevice'):
    d,b,h=collect_all(package)
    datas+=d; binaries+=b; hiddenimports+=h
datas+=collect_data_files('certifi')
a=Analysis([str(root/'desktop_app.py')],pathex=[str(root),str(project/'Tools'/'speaker')],binaries=binaries,datas=datas,
           hiddenimports=hiddenimports,excludes=['tensorflow','keras','matplotlib','IPython','notebook','pytest','torchaudio','torchvision'])
pyz=PYZ(a.pure)
exe=EXE(pyz,a.scripts,[],exclude_binaries=True,name='LingoClass',console=False,
        icon=str(project/'Desktop'/'public'/'app-icon.ico'))
coll=COLLECT(exe,a.binaries,a.datas,name='LingoClass')
if sys.platform == 'darwin':
    app=BUNDLE(coll,name='LingoClass.app',bundle_identifier='com.lingoclass.desktop',
        icon=str(project/'Desktop'/'public'/'app-icon.icns'),
        info_plist={'CFBundleDisplayName':'LingoClass','NSMicrophoneUsageDescription':'录制课堂声音并生成实时字幕。','NSHighResolutionCapable':True})
