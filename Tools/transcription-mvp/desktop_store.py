"""Shared course library and existing MVP recording index."""
import json
import re
import threading
import uuid
from datetime import datetime
from pathlib import Path

class DesktopStore:
    @staticmethod
    def schedule_fields(value):
        weekday=int(value.get('scheduleWeekday',1))
        monthday=int(value.get('scheduleMonthDay',1))
        clock=value.get('scheduleTime','09:00')
        if not 0<=weekday<=6 or not 1<=monthday<=31 or not re.fullmatch(r'(?:[01]\d|2[0-3]):[0-5]\d',str(clock)):
            raise ValueError('课程日期或时间无效')
        return {'scheduleWeekday':weekday,'scheduleMonthDay':monthday,'scheduleTime':clock}

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
        course.update(self.schedule_fields(value))
        with self.lock:
            data = self._read(); data['courses'].append(course); self._write(data)
        return course

    def edit_course(self, identifier, value):
        with self.lock:
            data=self._read()
            course=next((c for c in data['courses'] if c['id']==identifier),None)
            if course is None: raise ValueError('课程不存在')
            name=str(value.get('name',course['name'])).strip()
            if not name or len(name)>150: raise ValueError('请输入有效的课程名称')
            repeat=value.get('scheduleType',course.get('scheduleType','single'))
            if repeat not in ('single','daily','weekly','monthly'): raise ValueError('课程重复方式无效')
            schedule=self.schedule_fields({**course,**value})
            course.update(name=name,scheduleType=repeat,scheduleDate=value.get('scheduleDate',course.get('scheduleDate','')),accentCode=value.get('accentCode',course.get('accentCode','auto')))
            course.update(schedule)
            self._write(data)
            return course

    def delete_course(self, identifier):
        with self.lock:
            data=self._read()
            if not any(c['id']==identifier for c in data['courses']): raise ValueError('课程不存在')
            data['courses']=[c for c in data['courses'] if c['id']!=identifier]
            self._write(data)
        return {'ok':True}

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
        edits=path/'content-edits.json'
        if edits.exists(): record['content_edits']=json.loads(edits.read_text(encoding='utf-8'))
        classroom=path/'classroom-edits.json'
        if classroom.exists():
            manual=json.loads(classroom.read_text(encoding='utf-8'))
            record['content_edits']={**record.get('content_edits',{}),**manual.get('rows',{})}
            record['speaker_names']=manual.get('speaker_names',{})
        return record

    def edit_classroom(self, identifier, rows, speaker_names):
        with self.lock:
            record=self.record(identifier)
            valid={r['id'] for r in record.get('rows',[])}
            edits=dict(record.get('content_edits',{}))
            for row in rows:
                if row['id'] not in valid: raise ValueError('课堂段落不存在')
                original=str(row.get('original','')).strip();translated=str(row.get('translated','')).strip()
                if not original or max(len(original),len(translated))>20000: raise ValueError('课堂内容无效')
                edits[row['id']]={'original':original,'translated':translated}
            known={str(r['speaker_id']) for r in record.get('speaker_rows',{}).values() if r.get('speaker_id') is not None}
            names=dict(record.get('speaker_names',{}))
            for speaker,name in speaker_names.items():
                if speaker not in known: raise ValueError('说话人身份不存在')
                name=str(name).strip()
                if not name or len(name)>150: raise ValueError('说话人姓名无效')
                names[speaker]=name
            path=self.record_path(identifier)/'classroom-edits.json'
            temporary=path.with_suffix('.'+uuid.uuid4().hex+'.tmp')
            temporary.write_text(json.dumps({'rows':edits,'speaker_names':names},ensure_ascii=False,indent=2),encoding='utf-8');temporary.replace(path)
            return self.record(identifier)

    def edit_content(self, identifier, row_id, value):
        with self.lock:
            record=self.record(identifier)
            if row_id not in {row['id'] for row in record.get('rows',[])}: raise ValueError('课堂段落不存在')
            fields={key:str(value.get(key,'')).strip() for key in ('speaker','original','translated')}
            if not fields['original'] or len(fields['speaker'])>150 or any(len(fields[k])>20000 for k in ('original','translated')):
                raise ValueError('请输入有效的姓名和课堂内容')
            path=self.record_path(identifier)/'content-edits.json'
            edits=record.get('content_edits',{});edits[row_id]=fields
            temporary=path.with_suffix('.'+uuid.uuid4().hex+'.tmp')
            temporary.write_text(json.dumps(edits,ensure_ascii=False,indent=2),encoding='utf-8');temporary.replace(path)
            return self.record(identifier)

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
                                'title':data.get('record_titles',{}).get(directory.name) or ('【'+config.get('course_name','课堂')+'】'+directory.name[:8]),
                                'date':datetime.strptime(directory.name[:15],'%Y%m%d-%H%M%S').isoformat(),
                                'duration':result.get('metrics',{}).get('captured_seconds',0),'preview':text[:220]})
            except (ValueError,OSError,TypeError): continue
        return {'courses':data['courses'],'records':records,'settings':self.settings()}
