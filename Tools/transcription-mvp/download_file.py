"""Atomic downloads that preserve progress across interrupted connections."""
import re
import time
from pathlib import Path
from urllib.request import Request, urlopen


def download_file(url, target, progress=None, attempts=5, backoff=1):
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + '.part')
    for attempt in range(attempts):
        offset = partial.stat().st_size if partial.exists() else 0
        try:
            headers = {'User-Agent': 'LingoClass', 'Accept-Encoding': 'identity'}
            if offset:
                headers['Range'] = f'bytes={offset}-'
            with urlopen(Request(url, headers=headers), timeout=45) as response:
                if response.status == 206:
                    match = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', response.headers.get('Content-Range', ''))
                    if not match or int(match[1]) != offset:
                        raise ValueError('服务器返回的续传位置不正确')
                    total = int(match[3])
                    mode = 'ab'
                else:
                    # A server may ignore Range. Restart rather than duplicate bytes.
                    offset = 0
                    total = int(response.headers.get('Content-Length', 0))
                    mode = 'wb'
                if 'text/html' in response.headers.get('Content-Type', '').lower():
                    raise ValueError('下载服务器返回了网页，未获得模型文件')
                copied = offset
                with partial.open(mode) as output:
                    while True:
                        block = response.read(64 * 1024)
                        if not block:
                            break
                        output.write(block)
                        copied += len(block)
                        if progress:
                            progress(copied, total, attempt)
                if not copied or (total and copied != total):
                    raise ValueError('模型下载不完整')
                partial.replace(target)
                return target
        except Exception as error:
            if attempt + 1 == attempts:
                raise RuntimeError('下载连接中断，已保留下载进度，请点击重试继续。' + str(error)) from error
            if progress:
                progress(partial.stat().st_size if partial.exists() else 0, 0, attempt + 1)
            time.sleep(min(backoff * 2 ** attempt, 8))
