import Foundation

/// Semantic media snapshots. A process token distinguishes a restart from a reload.
enum MediaRecovery {
    static let runtime = UUID().uuidString
    static let script = makeScript(runtime: runtime)

    static func makeScript(runtime: String) -> String {
        """
        (() => {
          if (window.top !== window) return;
          const runtime = '\(runtime)';
          const route = () => location.pathname + location.search;
          const key = () => 'bowser-media-v2:' + location.host + route();
          const isX = /^(www\\.)?(x\\.com|twitter\\.com)$/.test(location.hostname);
          let pending=null, lastPlayed=null, routeAtLoad=route(), recoveryUI=null;
          try {
            const d=JSON.parse(localStorage.getItem(key()) || 'null');
            if(d && d.runtime!==runtime && Date.now()-d.at<120000 && Date.now()>=d.at && Number.isFinite(d.t)) pending=d;
          } catch(e) {}
          window.__bowserMediaRestoring=!!(pending && pending.tweet);
          // Cold native restart only. Warm before metadata arrives, since an
          // unmounted background player may need a mount to produce metadata.
          if(pending && pending.paused===false) {
            window.webkit?.messageHandlers?.bowserMediaWarm?.postMessage({runtime});
          }
          const deadline=Date.now()+20000;
          function tweet(m) {
            if(!isX) return null;
            const article=m.closest('article');
            const anchor=article?.querySelector('a:has(time)');
            const path=anchor ? new URL(anchor.href,location.href).pathname : location.pathname;
            const match=path.match(/^\\/[^/]+\\/status\\/(\\d+)/);
            return match ? {id:match[1], url:location.origin+match[0], article} : null;
          }
          function identity(m) {
            const tw=tweet(m);
            if(tw) return 'tweet:'+tw.id+':'+(tw.article ? Array.from(tw.article.querySelectorAll('video,audio')).indexOf(m) : 0);
            if(isX) return null; // Never apply a bookmarks snapshot to the first unrelated video.
            const src=m.currentSrc || m.src;
            if(src && !src.startsWith('blob:')) return src;
            return document.querySelectorAll('video,audio').length===1 ? 'single:'+route() : null;
          }
          function pick() {
            const all=Array.from(document.querySelectorAll('video,audio'));
            const full=document.fullscreenElement;
            return all.find(m=>m.webkitDisplayingFullscreen || (full && (full===m || full.contains(m)))) ||
              (lastPlayed?.isConnected && !lastPlayed.paused ? lastPlayed : null) ||
              all.find(m=>!m.paused && !m.ended) || (all.length===1 ? all[0] : null);
          }
          document.addEventListener('play', e=>{if(e.target.matches?.('video,audio')) lastPlayed=e.target;}, true);
          function finish() { pending=null; window.__bowserMediaRestoring=false; }
          function dismiss() { recoveryUI?.remove(); recoveryUI=null; }
          function offer(label, action) {
            if(recoveryUI || !document.body) return;
            const host=document.createElement('div'); recoveryUI=host;
            host.style.cssText='position:fixed;bottom:24px;right:24px;z-index:2147483647';
            const root=host.attachShadow({mode:'closed'});
            const button=document.createElement('button'); button.textContent=label;
            button.style.cssText='font:14px system-ui;padding:12px 18px;border:1px solid #777;border-radius:12px;background:#202124;color:white;cursor:pointer';
            button.onclick=()=>{action();dismiss();}; root.appendChild(button);
            const close=document.createElement('button'); close.textContent='×'; close.setAttribute('aria-label','Dismiss video recovery');
            close.style.cssText='font:18px system-ui;padding:10px;border:0;background:#202124;color:white;cursor:pointer';
            close.onclick=()=>{finish();dismiss();};root.appendChild(close);document.body.appendChild(host);
          }
          function save() {
            if(pending) return;
            const m=pick(); if(!m || !Number.isFinite(m.currentTime) || (m.paused && m.currentTime===0)) return;
            const id=identity(m); if(!id) return;
            const tw=tweet(m), full=document.fullscreenElement;
            const d={runtime, id, t:m.currentTime, paused:m.paused || m.ended, at:Date.now(),
              tweet:tw?.id, url:tw?.url, offset:tw?.article?.getBoundingClientRect().top ?? 0,
              fullscreen:!!(m.webkitDisplayingFullscreen || (full && (full===m || full.contains(m))))};
            try {localStorage.setItem(key(),JSON.stringify(d));} catch(e) {}
          }
          function fallback(d) {
            finish();
            if(d.tweet && d.url) offer('Resume video from tweet',()=>{
              const url=new URL(d.url);
              if(url.origin!==location.origin || !/^\\/[^/]+\\/status\\/\\d+$/.test(url.pathname)) return;
              // Transfer only this identified snapshot to the explicit user-selected permalink.
              d.runtime='';d.at=Date.now();
              localStorage.setItem('bowser-media-v2:'+url.host+url.pathname,JSON.stringify(d));
              location.assign(url.href);
            });
          }
          function tick() {
            if(route()!==routeAtLoad) {finish();dismiss();routeAtLoad=route();}
            if(!pending) {save();return;}
            const d=pending;
            const m=Array.from(document.querySelectorAll('video,audio')).find(m=>identity(m)===d.id);
            if(m && m.readyState>=1 && m.duration>0) {
              try {
                m.currentTime=Math.min(d.t, Number.isFinite(m.duration)?Math.max(0,m.duration-0.1):d.t);
                const tw=tweet(m);
                if(tw?.article) window.scrollBy(0,tw.article.getBoundingClientRect().top-d.offset);
                if(d.paused) m.pause(); else m.play().catch(()=>offer('Resume video',()=>m.play()));
                finish(); lastPlayed=m;
                if(d.fullscreen) offer('Resume fullscreen video',()=>{
                  if(m.requestFullscreen) m.requestFullscreen().catch(()=>{}); else m.webkitEnterFullscreen?.();
                  if(!d.paused) m.play().catch(()=>{});
                });
                return;
              } catch(e) {} // Metadata can arrive before a stream becomes seekable; retry.
            }
            if(Date.now()>deadline) {fallback(d);return;}
            if(d.tweet && !m) {
              // Advance only within the rendered span, keeping overlap so X can extend it.
              const articles=Array.from(document.querySelectorAll('article'));
              const last=articles.at(-1);
              if(last) window.scrollBy(0,Math.max(0,Math.min(window.innerHeight*0.6,last.getBoundingClientRect().bottom-window.innerHeight*0.6)));
            }
          }
          const cancel=()=>{if(pending) finish();dismiss();};
          window.addEventListener('wheel',cancel,{passive:true});
          window.addEventListener('keydown',cancel);
          window.addEventListener('pagehide',save);
          setInterval(tick,500);
        })();
        """
    }
}
