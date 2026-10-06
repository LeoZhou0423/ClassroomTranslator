"""Portable Word OOXML export, without a Word installation."""
import io
import re
import zipfile
from xml.sax.saxutils import escape

MIME='application/vnd.openxmlformats-officedocument.wordprocessingml.document'

def word_document(text,title='课堂记录'):
    if not str(text).strip():raise ValueError('没有可导出的内容')
    def paragraph(value,style):
        # XML 1.0 excludes these control characters; preserve all visible text.
        value=re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]','',value)
        return f'<w:p><w:pPr><w:pStyle w:val="{style}"/></w:pPr><w:r><w:t xml:space="preserve">{escape(value)}</w:t></w:r></w:p>'
    body=paragraph(title,'Title')+''.join(paragraph(line,'Translation' if re.search(r'[\u3400-\u9fff]',line) else 'Original') for line in text.splitlines())
    files={
        '[Content_Types].xml':'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>',
        '_rels/.rels':'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
        'word/_rels/document.xml.rels':'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>',
        'word/document.xml':f'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>{body}<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134"/></w:sectPr></w:body></w:document>',
        'word/styles.xml':'<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Microsoft YaHei"/><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:pPr><w:spacing w:after="300"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Original"><w:name w:val="Original"/><w:pPr><w:spacing w:after="100" w:line="300"/></w:pPr><w:rPr><w:color w:val="626975"/><w:sz w:val="21"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Translation"><w:name w:val="Translation"/><w:pPr><w:spacing w:after="180" w:line="330"/></w:pPr><w:rPr><w:color w:val="202124"/><w:sz w:val="23"/></w:rPr></w:style></w:styles>'}
    out=io.BytesIO()
    with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as bundle:
        for name,xml in files.items():bundle.writestr(name,'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+xml)
    return out.getvalue()
