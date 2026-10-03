extension ScriptWorker {
    static let bootstrap = #"""
    (() => {
      'use strict';
      const finish = __finish, bridge = __bridge, input = __input;
      delete globalThis.__finish; delete globalThis.__bridge; delete globalThis.__input;
      const pending = new Map();
      const error = (message, name = 'TypeError') => { const e = new Error(message); e.name = name; return e; };
      const unsupported = name => { throw error(`${name} is not supported by Requestman scripts`); };
      const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      const encode64 = bytes => {
        let out = '';
        for (let i = 0; i < bytes.length; i += 3) {
          const a = bytes[i], b = bytes[i + 1] ?? 0, c = bytes[i + 2] ?? 0;
          out += alphabet[a >> 2] + alphabet[((a & 3) << 4) | (b >> 4)] +
            (i + 1 < bytes.length ? alphabet[((b & 15) << 2) | (c >> 6)] : '=') +
            (i + 2 < bytes.length ? alphabet[c & 63] : '=');
        }
        return out;
      };
      const decode64 = text => {
        const count = text.length ? text.length / 4 * 3 - (text.endsWith('==') ? 2 : text.endsWith('=') ? 1 : 0) : 0;
        const bytes = new Uint8Array(count); let position = 0;
        for (let i = 0; i < text.length; i += 4) {
          const value = (alphabet.indexOf(text[i]) << 18) | (alphabet.indexOf(text[i + 1]) << 12) |
            ((text[i + 2] === '=' ? 0 : alphabet.indexOf(text[i + 2])) << 6) |
            (text[i + 3] === '=' ? 0 : alphabet.indexOf(text[i + 3]));
          if (position < count) bytes[position++] = (value >> 16) & 255;
          if (position < count) bytes[position++] = (value >> 8) & 255;
          if (position < count) bytes[position++] = value & 255;
        }
        return bytes;
      };
      const utf8 = bytes => {
        let out = '';
        for (let i = 0; i < bytes.length;) {
          const a = bytes[i++];
          if (a < 128) { out += String.fromCharCode(a); continue; }
          let count = a >= 0xc2 && a <= 0xdf ? 1 : a >= 0xe0 && a <= 0xef ? 2 : a >= 0xf0 && a <= 0xf4 ? 3 : 0;
          let value = a & (count === 1 ? 31 : count === 2 ? 15 : 7), valid = count > 0;
          for (let n = 0; valid && n < count; n++) {
            const b = bytes[i];
            if (b === undefined || b < 0x80 || b > 0xbf ||
                (n === 0 && ((a === 0xe0 && b < 0xa0) || (a === 0xed && b > 0x9f) ||
                              (a === 0xf0 && b < 0x90) || (a === 0xf4 && b > 0x8f)))) { valid = false; break; }
            value = (value << 6) | (b & 63); i++;
          }
          out += valid ? String.fromCodePoint(value) : '\ufffd';
        }
        return out.charCodeAt(0) === 0xfeff ? out.slice(1) : out;
      };
      const encodeText = text => {
        const bytes = [];
        for (let i = 0; i < text.length; i++) {
          let c = text.codePointAt(i);
          if (c > 0xffff) i++;
          else if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd;
          if (c < 0x80) bytes.push(c);
          else if (c < 0x800) bytes.push(0xc0 | (c >> 6), 0x80 | (c & 63));
          else if (c < 0x10000) bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
          else bytes.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        }
        return new Uint8Array(bytes);
      };
      class Headers {
        constructor(init = undefined, immutable = false) {
          this._entries = []; this._immutable = false;
          if (init instanceof Headers) init = init._entries;
          else if (init !== undefined && init !== null && typeof init !== 'string' && typeof init[Symbol.iterator] === 'function') init = [...init];
          if (Array.isArray(init)) {
            for (const pair of init) {
              if (!Array.isArray(pair) || pair.length !== 2) throw error('Each Header must be a name/value pair');
              this.append(pair[0], pair[1]);
            }
          } else if (init !== undefined && init !== null && typeof init === 'object') {
            for (const [name, value] of Object.entries(init)) this.append(name, value);
          } else if (init !== undefined && init !== null) throw error('Invalid Headers input');
          this._immutable = immutable;
        }
        _name(name) {
          name = String(name).toLowerCase();
          if (!/^[!#$%&'*+.^_`|~0-9a-z-]+$/.test(name)) throw error('Invalid Header name');
          return name;
        }
        _write() { if (this._immutable) throw error('Response Headers are immutable'); }
        append(name, value) {
          this._write(); name = this._name(name); value = String(value).trim();
          if (/[\x00-\x08\x0a-\x1f\x7f]/.test(value)) throw error('Invalid Header value');
          this._entries.push([name, value]);
        }
        set(name, value) {
          this._write(); name = this._name(name);
          const checked = new Headers([[name, value]])._entries[0];
          this.delete(name); this._entries.push(checked);
        }
        delete(name) { this._write(); name = this._name(name); this._entries = this._entries.filter(e => e[0] !== name); }
        has(name) { name = this._name(name); return this._entries.some(e => e[0] === name); }
        get(name) { name = this._name(name); const values = this._entries.filter(e => e[0] === name).map(e => e[1]); return values.length ? values.join(', ') : null; }
        getSetCookie() { return this._entries.filter(e => e[0] === 'set-cookie').map(e => e[1]); }
        *entries() { for (const name of [...new Set(this._entries.map(e => e[0]))].sort()) yield [name, this.get(name)]; }
        *keys() { for (const [name] of this.entries()) yield name; }
        *values() { for (const [, value] of this.entries()) yield value; }
        [Symbol.iterator]() { return this.entries(); }
        forEach(callback, thisArg) { for (const [name, value] of this.entries()) callback.call(thisArg, value, name, this); }
      }
      class AbortSignal {
        constructor() { this.aborted = false; this.reason = undefined; this._listeners = new Set(); this.onabort = null; }
        addEventListener(type, listener) { if (type !== 'abort') unsupported(`AbortSignal event ${type}`); if (typeof listener !== 'function') throw error('Invalid abort listener'); this._listeners.add(listener); }
        removeEventListener(type, listener) { if (type === 'abort') this._listeners.delete(listener); }
        throwIfAborted() { if (this.aborted) throw this.reason; }
        _abort(reason) {
          if (this.aborted) return;
          this.aborted = true; this.reason = reason ?? error('The operation was aborted', 'AbortError');
          const event = { type: 'abort', target: this };
          for (const callback of this._listeners) { try { callback(event); } catch (_) {} }
          if (typeof this.onabort === 'function') { try { this.onabort(event); } catch (_) {} }
        }
        static abort(reason) { const signal = new AbortSignal(); signal._abort(reason); return signal; }
        static timeout() { unsupported('AbortSignal.timeout'); }
        static any() { unsupported('AbortSignal.any'); }
      }
      class AbortController {
        constructor() { this.signal = new AbortSignal(); }
        abort(reason) { this.signal._abort(reason); }
      }
      const fetch = (url, init = {}) => {
        let id, entry;
        try {
          if (typeof url !== 'string') throw error('fetch requires an absolute HTTP/HTTPS URL string');
          if (!init || typeof init !== 'object' || Array.isArray(init)) throw error('Invalid fetch options');
          for (const name of Object.keys(init)) if (!['method','headers','body','redirect','signal'].includes(name)) unsupported(`fetch option ${name}`);
          const signal = init.signal;
          if (signal !== undefined && !(signal instanceof AbortSignal)) throw error('fetch signal must be an AbortSignal');
          signal?.throwIfAborted();
          // Bound native submissions before encoding or scheduling pipe writes, including abort storms.
          if (pending.size >= 36) throw error('Auxiliary fetch admission is full');
          const method = String(init.method ?? 'GET').toUpperCase();
          const redirect = init.redirect ?? 'follow';
          if (!['follow','manual','error'].includes(redirect)) throw error('Invalid fetch redirect option');
          const headers = new Headers(init.headers);
          let body = null;
          if (init.body !== undefined && init.body !== null) {
            if (typeof init.body === 'string') {
              body = encode64(encodeText(init.body));
              if (!headers.has('content-type')) headers.set('content-type', 'text/plain;charset=UTF-8');
            } else if (init.body instanceof ArrayBuffer) body = encode64(new Uint8Array(init.body));
            else if (ArrayBuffer.isView(init.body)) body = encode64(new Uint8Array(init.body.buffer, init.body.byteOffset, init.body.byteLength));
            else unsupported('fetch body type (streams/FormData/Blob/URLSearchParams)');
          }
          if ((method === 'GET' || method === 'HEAD') && body !== null) throw error('GET/HEAD requests cannot contain a body');
          const request = { url, method, redirect, headers: headers._entries.map(([name,value]) => ({name,value})), body };
          id = bridge('fetch', JSON.stringify(request));
          if (!id) throw error('Auxiliary IPC admission is full');
          const promise = new Promise((resolve, reject) => { entry = { resolve, reject, signal, body: null, chunks: [], consumed: false }; pending.set(id, entry); });
          if (signal) {
            entry.abort = () => {
              // Keep the permit until the host acknowledges abort; a tight loop cannot refill IPC infinitely.
              bridge('abort', id);
              entry.reject(signal.reason); entry.body?.reject(signal.reason);
            };
            signal.addEventListener('abort', entry.abort);
          }
          return promise;
        } catch (e) { return Promise.reject(e); }
      };
      const consume = (id, entry) => {
        if (entry.consumed) return Promise.reject(error('Response body has already been consumed'));
        entry.consumed = true;
        if (entry.signal?.aborted) return Promise.reject(entry.signal.reason);
        return new Promise((resolve, reject) => {
          entry.body = { resolve, reject };
          if (!bridge('body', id)) reject(error('Auxiliary IPC admission is full'));
        });
      };
      const response = (id, entry, meta) => ({
        status: meta.status, statusText: meta.statusText, ok: meta.status >= 200 && meta.status < 300,
        url: meta.url, redirected: meta.redirected, type: 'basic',
        headers: new Headers(meta.headers.map(h => [h.name, h.value]), true),
        get bodyUsed() { return entry.consumed; },
        get body() { unsupported('Response.body streams'); },
        text() { return consume(id, entry).then(utf8); },
        json() { return consume(id, entry).then(bytes => JSON.parse(utf8(bytes))); },
        arrayBuffer() { return consume(id, entry).then(bytes => bytes.buffer); },
        clone() { unsupported('Response.clone'); }, blob() { unsupported('Response.blob'); }, formData() { unsupported('Response.formData'); }
      });
      Object.assign(globalThis, { fetch, Headers, AbortController, AbortSignal });
      for (const name of ['setTimeout','setInterval','clearTimeout','clearInterval','FormData','ReadableStream','Request','Response']) {
        globalThis[name] = function() { unsupported(name); };
      }
      const freeze = value => {
        if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); }
        return value;
      };
      const { source, request, response: incoming = null, env: rawEnv, environmentTypes } = input;
      const env = Object.fromEntries(Object.entries(rawEnv).map(([name, value]) =>
        [name, !environmentTypes[name] || environmentTypes[name] === 'string' ? value : JSON.parse(value)]));
      request.body ??= null; if (incoming) incoming.body ??= null;
      freeze(env); if (incoming) freeze(request);
      const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
      Promise.resolve().then(() => new AsyncFunction('request','response','env', '"use strict";\n' + source)(request, incoming, env)).then(result => {
        if (!result || typeof result !== 'object') throw error('Script must return the current request or response object');
        if (!Array.isArray(result.headers)) throw error('headers must be a name/value array');
        if (result.body !== null && typeof result.body !== 'string') throw error('body must be a UTF-8 string or null');
        for (const header of result.headers) if (!header || typeof header.name !== 'string' || typeof header.value !== 'string') throw error('Each Header must contain string name/value');
        if (incoming ? !Number.isInteger(result.status) : typeof result.method !== 'string' || typeof result.url !== 'string') throw error('Invalid script request/response fields');
        finish(JSON.stringify(incoming ? {status:result.status,headers:result.headers,body:result.body} :
          {method:result.method,url:result.url,headers:result.headers,body:result.body}), null);
      }).catch(e => finish(null, `${e?.name ?? 'Error'}: ${e?.message ?? String(e)}`));
      return (kind, id, encoded, failure) => {
        const entry = pending.get(id); if (!entry) return;
        if (kind === 'headers') entry.resolve(response(id, entry, JSON.parse(utf8(decode64(encoded)))));
        else if (kind === 'bodyChunk') entry.chunks.push(decode64(encoded));
        else if (kind === 'bodyEnd') {
          const bytes = new Uint8Array(entry.chunks.reduce((sum, chunk) => sum + chunk.length, 0));
          let offset = 0; for (const chunk of entry.chunks) { bytes.set(chunk, offset); offset += chunk.length; }
          pending.delete(id); if (entry.abort) entry.signal.removeEventListener('abort', entry.abort);
          entry.body?.resolve(bytes); entry.chunks = [];
        } else if (kind === 'error') {
          pending.delete(id); if (entry.abort) entry.signal.removeEventListener('abort', entry.abort);
          const reason = error(failure, failure.startsWith('AbortError') ? 'AbortError' : 'TypeError');
          entry.reject(reason); entry.body?.reject(reason);
        }
      };
    })()
    """#
}
