import { useEffect, useRef } from 'react'
import { X } from 'lucide-react'

type Caption = {id:string;original:string;translated:string}

export function SubtitleOverlay({caption,onClose}:{caption:Caption|null;onClose:()=>void}) {
 const viewport=useRef<HTMLDivElement>(null)
 useEffect(()=>{
  const element=viewport.current
  if(element)element.scrollTo({top:element.scrollHeight,behavior:window.matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth'})
 },[caption?.original,caption?.translated])
 return <div className="subtitle-window">
  <div className="overlay-handle"><span>课堂字幕</span><button aria-label="关闭字幕" onClick={onClose}><X size={14}/></button></div>
  <div className="subtitle-viewport" ref={viewport} aria-live="polite" aria-atomic="true">
   {caption?<section className="subtitle-current" key={caption.id}><p>{caption.original}</p>{caption.translated&&<strong>{caption.translated}</strong>}</section>:<span className="subtitle-empty">等待课堂字幕…</span>}
  </div>
 </div>
}
