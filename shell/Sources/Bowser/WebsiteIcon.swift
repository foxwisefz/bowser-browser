/// WebKit provides page-scoped network access and decoded candidates.
/// Selection, rendering, caches and retries belong to the Elixir brain.
enum WebsiteIcon {
    nonisolated static let probe = #"""
    const links = d => Array.from(d.querySelectorAll('link[rel]')).filter(l => /(^|\s)(icon|shortcut|apple-touch-icon|manifest)(\s|$)/i.test(l.rel));
    const candidates = [];
    const manifests = [];
    function collect(doc, base) {
      for (const link of links(doc)) {
        try {
          const url = new URL(link.getAttribute('href'), base).href;
          if (!/^(https?:|data:image\/)/i.test(url)) continue;
          if (link.rel === 'manifest') { manifests.push(url); continue; }
          candidates.push({url, size: parseInt(link.getAttribute('sizes')) || 0,
            vector: /svg/i.test(link.type || '') || /\.svg([?#]|$)/i.test(url) || url.startsWith('data:image/svg'),
            app: /apple-touch-icon/.test(link.rel)});
        } catch (_) {}
      }
    }
    async function fetchText(url) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 2000);
      try {
        const response = await fetch(url, {signal: controller.signal});
        if (!response.ok) throw Error('icon metadata unavailable');
        const text = await response.text();
        if (text.length > 2000000) throw Error('icon metadata too large');
        return {text, url: response.url};
      } finally { clearTimeout(timer); }
    }
    // Notification badges often replace the original link with a data PNG.
    // Re-read the original declarations only in that case, never site-specific.
    if (/^https?:$/.test(location.protocol) && links(document).some(l => /^data:image\/(png|webp)/i.test(l.href))) {
      try {
        const original = await fetchText(location.href);
        collect(new DOMParser().parseFromString(original.text, 'text/html'), original.url);
      } catch (_) {}
    }
    const hasCleanIcon = candidates.length > 0;
    const originalCount = candidates.length;
    collect(document, document.baseURI);
    if (hasCleanIcon) {
      for (let i = candidates.length - 1; i >= originalCount; --i) {
        if (/^data:image\/(png|webp)/i.test(candidates[i].url)) candidates.splice(i, 1);
      }
    }
    await Promise.all([...new Set(manifests)].slice(0, 2).map(async url => {
      try {
        const response = await fetchText(url), manifest = JSON.parse(response.text);
        for (const icon of (manifest.icons || []).slice(0, 12)) {
          if ((icon.purpose || 'any').split(' ').every(p => p === 'monochrome')) continue;
          const src = new URL(icon.src, response.url).href;
          if (!/^https?:/i.test(src)) continue;
          candidates.push({url: src, size: parseInt(icon.sizes) || 0,
            vector: /svg/i.test(icon.type || ''), app: true});
        }
      } catch (_) {}
    }));
    if (!candidates.length && /^https?:$/.test(location.protocol)) candidates.push({url: location.origin + '/favicon.ico'});
    const seen = new Set();
    const ranked = candidates.sort((a,b) => ((b.vector ? 512 : b.size || 32) + (b.app ? 1 : 0)) - ((a.vector ? 512 : a.size || 32) + (a.app ? 1 : 0)))
      .filter(c => !seen.has(c.url) && seen.add(c.url)).slice(0, 10);
    const results = await Promise.all(ranked.map(async candidate => {
      try {
        const image = new Image(); image.crossOrigin = 'anonymous';
        await new Promise((resolve, reject) => {
          const timer = setTimeout(() => { image.src = ''; reject(Error('icon timeout')); }, 2500);
          image.onload = () => { clearTimeout(timer); resolve(); };
          image.onerror = () => { clearTimeout(timer); reject(Error('invalid icon')); };
          image.src = candidate.url;
        });
        if (!image.naturalWidth || !image.naturalHeight) return null;
        const longest = Math.max(image.naturalWidth, image.naturalHeight);
        const scale = (candidate.vector ? 512 : Math.min(512, longest)) / longest;
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
        canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
        canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
        return {width: canvas.width, height: canvas.height, app: !!candidate.app, png: canvas.toDataURL('image/png').split(',')[1]};
      } catch (_) {
        // A CDN may reject canvas/CORS access. Let the brain try a public
        // fetch outside both WebKit and the browser process.
        return /^https?:/i.test(candidate.url) ? {url: candidate.url,
          width: Math.min(512, candidate.size || 32), height: Math.min(512, candidate.size || 32), app: !!candidate.app} : null;
      }
    }));
    return results.filter(Boolean);
    """#

}
