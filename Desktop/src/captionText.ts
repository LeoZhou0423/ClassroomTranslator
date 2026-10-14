export const hasUnclear=(text:string)=>/\[\s*unclear\b[^\]]*\]/i.test(text)
export const stripAnnotations=(text:string)=>hasUnclear(text)?'':text.replace(/\[[^\]]*\]|【[^】]*】/g,'').replace(/\s+/g,' ').trim()
export function sanitizeCaption<T extends {original:string;translated:string}>(caption:T):T|null{
 const original=stripAnnotations(caption.original)
 if(!original)return null
 return {...caption,original,translated:stripAnnotations(caption.translated)}
}
