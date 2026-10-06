"""Launch the actual bundled executable without requesting microphone access."""
import json
from pathlib import Path
import subprocess
import time
import requests

app=Path('Releases/macOS/LingoClass.app/Contents/MacOS/LingoClass').resolve()
process=subprocess.Popen([str(app),'--port','8800'],cwd='/tmp')
try:
    for attempt in range(90):
        if process.poll() is not None:
            raise RuntimeError(f'Bundled application exited: {process.returncode}')
        try:
            response=requests.get('http://127.0.0.1:8800/api/config',timeout=2)
            response.raise_for_status()
            config=response.json()
            break
        except requests.RequestException:
            time.sleep(1)
    else:
        raise RuntimeError('Bundled application failed to start its local service')
    assert any(m['name']=='small' and m['ready'] for m in config['models'])
    response=requests.get('http://127.0.0.1:8800/',timeout=10)
    response.raise_for_status()
    assert 'root' in response.text
    print(json.dumps({'bundled_app_started':True,'small_model_ready':True,'frontend_ready':True}))
finally:
    process.terminate()
    try:process.wait(timeout=15)
    except subprocess.TimeoutExpired:process.kill();process.wait()
