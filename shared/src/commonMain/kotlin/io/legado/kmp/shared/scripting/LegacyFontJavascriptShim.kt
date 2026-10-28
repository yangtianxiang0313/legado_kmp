package io.legado.kmp.shared.scripting

internal val LEGACY_FONT_SHIM = """
    (function(query, call, mapCall, replace, release) {
      var ids = new WeakMap();
      var objects = new Map();
      function handle(font) {
        if (font == null) return null;
        var id = ids.get(font);
        if (id === undefined) throw new TypeError('Expected a queryTTF font object');
        return id;
      }
      function fontMap(id, name) {
        function send(operation, key) {
          return JSON.parse(mapCall(id, name, operation, key == null ? null : String(key)));
        }
        var result = {
          get: function(key) { return send('get', key); },
          containsKey: function(key) { return send('contains', key); },
          size: function() { return send('size'); },
          isEmpty: function() { return send('size') === 0; },
          keySet: function() { return send('keys'); },
          values: function() {
            var snapshot = send('snapshot');
            return send('keys').map(function(key) { return snapshot[key]; });
          },
          entrySet: function() {
            var snapshot = send('snapshot');
            return send('keys').map(function(key) {
              return { getKey: function() { return key; }, getValue: function() { return snapshot[key]; } };
            });
          },
          toJSON: function() { return send('snapshot'); },
          toString: function() { return JSON.stringify(send('snapshot')); }
        };
        return Object.freeze(result);
      }
      function wrap(id) {
        if (id == null) return null;
        if (objects.has(id)) return objects.get(id);
        var result = {};
        ['getGlyfById', 'getGlyfIdByUnicode', 'getGlyfByUnicode', 'getUnicodeByGlyf', 'isBlankUnicode'].forEach(function(name) {
          result[name] = function(value) {
            var argument = name === 'getUnicodeByGlyf' ? (value == null ? null : String(value)) : Number(value);
            if (name !== 'getUnicodeByGlyf' && !Number.isInteger(argument)) {
              throw new TypeError('Font query requires an integer');
            }
            return call(id, name, argument);
          };
        });
        ['unicodeToGlyph', 'unicodeToGlyphId', 'glyphToUnicode'].forEach(function(name) {
          Object.defineProperty(result, name, { enumerable: true, value: fontMap(id, name) });
        });
        result.close = function() { release(id); objects.delete(id); };
        ids.set(result, id);
        objects.set(id, result);
        return Object.freeze(result);
      }
      java.queryTTF = function(data, useCache) {
        if (data == null) return null;
        var mode = 'string';
        var payload = data;
        if (typeof ArrayBuffer === 'function' && data instanceof ArrayBuffer) {
          payload = new Uint8Array(data);
        } else if (typeof ArrayBuffer === 'function' && ArrayBuffer.isView(data)) {
          payload = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
        }
        if (Array.isArray(payload) || (typeof ArrayBuffer === 'function' && ArrayBuffer.isView(payload))) {
          if (payload.length > ${LegacyFontLimits.MAX_BYTES}) throw new RangeError('Font byte input limit exceeded');
          mode = 'bytes';
          payload = JSON.stringify(Array.from(payload, function(value) {
            if (!Number.isInteger(value) || value < -128 || value > 255) {
              throw new TypeError('Invalid font ByteArray value');
            }
            return value > 127 ? value - 256 : value;
          }));
        } else if (typeof payload !== 'string') {
          return null;
        }
        var headers = JSON.stringify(java.__headerMap.toJSON());
        return wrap(query(mode, payload, useCache !== false, headers));
      };
      java.queryBase64TTF = function(data) { return java.queryTTF(data); };
      java.replaceFont = function(text, errorFont, correctFont, filter) {
        return replace(String(text), handle(errorFont), handle(correctFont), filter === true);
      };
    })(__legacyQueryTTF, __legacyFontCall, __legacyFontMap, __legacyReplaceFont, __legacyFontRelease);
""".trimIndent()
