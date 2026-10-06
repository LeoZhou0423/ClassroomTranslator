"""Shared course library and existing MVP recording index."""
import json
import re
import threading
import uuid
from datetime import datetime
from pathlib import Path

class DesktopStore:
    def __init__(self, root):
        self.root = Path(root)
        self.path = self.root / 'library.json'
        self.lock = threading.RLock()

    def _read(self):
        if not self.path.exists():
            return {'courses': [], 'settings': {}}
        return json.loads(self.path.read_text(encoding='utf-8'))

    def _write(self, data):
        self.root.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix('.'+uuid.uuid4().hex+'.tmp')
        temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
        temporary.replace(self.path)

    def settings(self):
        with self.lock:
            return {'model':'small','device':None,'font_size':15,'auto_scroll':True,'noise_reduction':True, **self._read().get('settings',{})}

    def update_settings(self, settings):
        allowed = {'model','device','font_size','auto_scroll','translation_endpoint','noise_reduction'}
        with self.lock:
            data = self._read()
            data['settings'].update({k:v for k,v in settings.items() if k in allowed})
            self._write(data)
        return self.settings()

    def create_course(self, value):
        name = str(value.get('name','')).strip()
        if not name or len(name)>150:
            raise ValueError('请输入有效的课程名称')
        course = {'id':str(uuid.uuid4()),'name':name,'accentCode':value.get('accentCode','auto'),
                  'targetLanguageCode':'zh-Hans','createdAt':datetime.now().isoformat(),
                  'scheduleType':value.get('scheduleType','single'),'scheduleDate':value.get('scheduleDate','')}
        if course['scheduleType'] not in ('single','daily','weekly','monthly'):
            raise ValueError('课程重复方式无效')
        with self.lock:
            data = self._read(); data['courses'].append(course); self._write(data)
        return course

    def rename_record(self, identifier, title):
        title=str(title).strip()
        if not title or len(title)>150: raise ValueError('请输入有效的课堂记录名称')
        self.record_path(identifier)
        with self.lock:
            data=self._read();data.setdefault('record_titles',{})[identifier]=title;self._write(data)
        return {'id':identifier,'title':title}

    def record_path(self, identifier):
        if not re.fullmatch(r'\d{8}-\d{6}-[a-z0-9]+', identifier):
            raise ValueError('录音记录编号无效')
        path = self.root / 'sessions' / identifier
        if not path.is_dir(): raise ValueError('录音记录不存在')
        return path

    def record(self, identifier):
        path = self.record_path(identifier)
        result = path / 'result.json'
        if not result.exists(): raise ValueError('录音尚未保存')
        record = json.loads(result.read_text(encoding='utf-8'))
        language = path / 'language.json'
        if language.exists(): record['language_rows'] = json.loads(language.read_text(encoding='utf-8'))
        speakers=path/'speakers.json'
        if speakers.exists(): record['speaker_rows']=json.loads(speakers.read_text(encoding='utf-8'))
        record['id'] = identifier
        return record

    def library(self):
        with self.lock: data = self._read()
        records=[]
        sessions=self.root/'sessions'
        for directory in sorted(sessions.glob('*'), reverse=True) if sessions.exists() else []:
            if not (directory/'result.json').is_file(): continue
            try:
                result=json.loads((directory/'result.json').read_text(encoding='utf-8'))
                config=result.get('config',{})
                text=result.get('transcript','')
                if not text.strip(): continue
                records.append({'id':directory.name,'course_id':config.get('course_id'),
                                'title':data.get('record_titles',{}).get(directory.name) or config.get('course_name') or directory.name[:15],
                                'date':datetime.strptime(directory.name[:15],'%Y%m%d-%H%M%S').isoformat(),
                                'duration':result.get('metrics',{}).get('captured_seconds',0),'preview':text[:220]})
            except (ValueError,OSError,TypeError): continue
        return {'courses':data['courses'],'records':records,'settings':self.settings()}
