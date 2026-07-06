import Foundation

/// JavaScript snippets used by the embedded WKWebView to discover m3u8 URLs
/// in a fully-rendered page (after JS has run, video players initialised, etc.).
///
/// Two scripts:
///   • `monkeyPatch` — installed at document-start in every frame; wraps
///     `window.fetch` and `XMLHttpRequest` so every URL that touches the page
///     (including dynamic XHRs from video players like DPlayer / Clappr /
///     videojs / hls.js) is recorded into `window.__m3u8Observed` if it
///     contains ".m3u8".
///   • `extractScript` — called on demand (after the page settles, or on
///     user click) via `evaluateJavaScript`. It walks the live DOM, reads
///     every `<script>` text content, also pulls the observed m3u8 list, and
///     returns a single deduped array of absolute URLs.
enum JSExtractor {

    /// Install once per frame, at document-start.
    static let monkeyPatch: String = #"""
    (function(){
      if (window.__m3u8Installed) return;
      window.__m3u8Installed = true;
      window.__m3u8Observed = window.__m3u8Observed || [];
      function record(u){
        try {
          if (typeof u !== 'string' && !(u instanceof String)) return;
          if (u.indexOf('.m3u8') === -1) return;
          if (window.__m3u8Observed.indexOf(u) === -1) window.__m3u8Observed.push(u);
        } catch(e){}
      }
      // window.fetch
      try {
        var origFetch = window.fetch;
        if (origFetch) {
          window.fetch = function(input, init){
            try {
              var url = (typeof input === 'string') ? input : (input && input.url);
              if (url) record(String(url));
            } catch(e){}
            return origFetch.apply(this, arguments);
          };
        }
      } catch(e){}
      // XMLHttpRequest
      try {
        var OrigXHR = window.XMLHttpRequest;
        if (OrigXHR) {
          function PatchedXHR(){
            var xhr = new OrigXHR();
            var _open = xhr.open;
            xhr.open = function(method, url){
              try { if (url) record(String(url)); } catch(e){}
              return _open.apply(this, arguments);
            };
            return xhr;
          }
          PatchedXHR.prototype = OrigXHR.prototype;
          Object.defineProperty(PatchedXHR, 'name', { value: 'XMLHttpRequest' });
          window.XMLHttpRequest = PatchedXHR;
        }
      } catch(e){}
      // EventSource
      try {
        var OrigES = window.EventSource;
        if (OrigES) {
          window.EventSource = function(url, conf){
            try { if (url) record(String(url)); } catch(e){}
            return new OrigES(url, conf);
          };
        }
      } catch(e){}
    })();
    """#

    /// Run on demand. Returns an array of absolute m3u8 URLs.
    /// Sources (in priority order):
    ///   1. `window.__m3u8Observed` (network calls — most reliable)
    ///   2. live DOM: `<video>`, `<source>`, `<iframe>`, `<a>`, `<embed>`,
    ///      `<object>` — src / href / data-* / currentSrc
    ///   3. inline `<script>` text content
    ///   4. full rendered HTML outerHTML
    static let extractScript: String = #"""
    (function(){
      function unesc(s){
        try {
          return String(s).replace(/\\\//g, '/').replace(/\\u002F/g, '/');
        } catch(e){ return s; }
      }
      function pick(text){
        var out = [];
        try {
          var re = /https?:\/\/[^"'<>)\]\}\s]+?\.m3u8(?:\?[^"'<>)\]\}\s]*)?/g;
          var t = unesc(text);
          var m;
          while ((m = re.exec(t)) !== null) {
            var v = m[0].replace(/[.,;)\]}'"]+$/, '');
            if (out.indexOf(v) === -1) out.push(v);
          }
        } catch(e){}
        return out;
      }
      function absolutize(u){
        try { return new URL(u, document.baseURI).href; }
        catch(e){ return u; }
      }
      var dom = [];
      try {
        var nodes = document.querySelectorAll('video, source, iframe, a, embed, object, link');
        for (var i=0; i<nodes.length; i++){
          var el = nodes[i];
          var attrs = ['src','href','data-src','data-url','data-video','data-href','poster'];
          for (var j=0; j<attrs.length; j++){
            var v = el.getAttribute && el.getAttribute(attrs[j]);
            if (v && v.indexOf('.m3u8') !== -1) dom.push(absolutize(v));
          }
          try { if (el.currentSrc) dom.push(el.currentSrc); } catch(e){}
          try { if (el.src) dom.push(el.src); } catch(e){}
        }
      } catch(e){}
      var fromScripts = [];
      try {
        var scripts = document.querySelectorAll('script');
        for (var k=0; k<scripts.length; k++){
          fromScripts = fromScripts.concat(pick(scripts[k].textContent || ''));
        }
      } catch(e){}
      var observed = [];
      try { observed = (window.__m3u8Observed || []).slice(); } catch(e){}
      var fromHTML = pick(document.documentElement.outerHTML || '');
      var seen = {}; var flat = [];
      function add(arr){
        for (var p=0; p<arr.length; p++){
          var u = arr[p];
          if (!u) continue;
          if (seen[u]) continue;
          seen[u] = 1;
          flat.push(u);
        }
      }
      add(observed);
      add(dom);
      add(fromScripts);
      add(fromHTML);
      return flat;
    })();
    """#
}
