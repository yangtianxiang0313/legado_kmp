package io.legado.kmp.shared.scripting

// HttpConnection / Connection at https://github.com/jhy/jsoup/tree/jsoup-1.16.2.
internal val LEGACY_JS_JAVA_JSOUP_SUPPORT = """
    var jsoupHostExecute = typeof __legacyJsoupExecute === 'function' ? __legacyJsoupExecute : null;
    var jsoupHostDecodeBytes = __legacyJsoupDecodeBytes;
    var jsoupSetPrototype = Object.setPrototypeOf;
    var jsoupPrivate = new WeakMap();
    var jsoupPrivateGet = Function.prototype.call.bind(WeakMap.prototype.get, jsoupPrivate);
    var jsoupPrivateSet = Function.prototype.call.bind(WeakMap.prototype.set, jsoupPrivate);
    var jsoupRegexExec = Function.prototype.call.bind(RegExp.prototype.exec);
    var jsoupStringCtor = JString, jsoupMapCtor = JHashMap, jsoupListCtor = JArrayList;
    var jsoupFormEncode = JURLEncoder.encode;
    var jsoupMethods = create(null), jsoupMethodValues = [];

    function jsoupArray() { return jsoupSetPrototype([], null); }
    function jsoupAppend(array, value) { field(array, array.length, value); }
    function jsoupTest(pattern, value) { return jsoupRegexExec(pattern, value) !== null; }
    function jsoupString(value, label, nonempty) {
      value = unbox(value);
      if (typeof value !== 'string' || nonempty && value.length === 0) {
        throw new fail('IllegalArgumentException: ' + label + ' must be ' + (nonempty ? 'a nonempty string' : 'a string'));
      }
      return value;
    }
    function jsoupInt(value, label) {
      value = unbox(value);
      if (typeof value !== 'number' || !integer(value) || value < 0 || value > 2147483647) {
        throw new outOfBounds('IllegalArgumentException: ' + label + ' must be an int in [0, 2147483647]');
      }
      return value;
    }
    function jsoupBoolean(value, label) {
      value = unbox(value);
      if (typeof value !== 'boolean') throw new fail('IllegalArgumentException: ' + label + ' must be boolean');
      return value;
    }
    function jsoupUnsupported(name) {
      return function() { throw new fail('UnsupportedOperationException: org.jsoup.' + name + ' is not supported by the host bridge'); };
    }
    function jsoupReject(target, prefix, names) {
      for (var i = 0; i < names.length; i++) method(target, names[i], jsoupUnsupported(prefix + '.' + names[i]));
    }
    function jsoupPrivateData(value, kind) {
      var data = value !== null && (typeof value === 'object' || typeof value === 'function') ? jsoupPrivateGet(value) : null;
      if (!data || data.kind !== kind) throw new fail('IllegalArgumentException: expected a supported Jsoup ' + kind);
      return data;
    }
    function jsoupMethod(name, ordinal, body) {
      var target = create(null), data = create(null);
      data.kind = 'method'; data.name = name; data.ordinal = ordinal; data.hasBody = body;
      jsoupPrivateSet(target, data);
      method(target, 'name', function() { arity(arguments, 0, 0, 'Method.name'); return jsoupStringCtor(name); });
      method(target, 'ordinal', function() { arity(arguments, 0, 0, 'Method.ordinal'); return ordinal; });
      method(target, 'hasBody', function() { arity(arguments, 0, 0, 'Method.hasBody'); return body; });
      method(target, 'toString', function() { arity(arguments, 0, 0, 'Method.toString'); return name; });
      method(target, primitiveKey, function() { return name; });
      field(jsoupMethods, name, freeze(target)); jsoupAppend(jsoupMethodValues, target);
    }
    jsoupMethod('GET', 0, false); jsoupMethod('POST', 1, true); jsoupMethod('PUT', 2, true);
    jsoupMethod('DELETE', 3, true); jsoupMethod('PATCH', 4, true); jsoupMethod('HEAD', 5, false);
    jsoupMethod('OPTIONS', 6, false); jsoupMethod('TRACE', 7, false);
    method(jsoupMethods, 'values', function() { arity(arguments, 0, 0, 'Method.values'); return slice(jsoupMethodValues); });
    method(jsoupMethods, 'valueOf', function(value) {
      arity(arguments, 1, 1, 'Method.valueOf'); value = jsoupString(value, 'method name', true);
      for (var i = 0; i < jsoupMethodValues.length; i++) {
        if (jsoupPrivateGet(jsoupMethodValues[i]).name === value) return jsoupMethodValues[i];
      }
      throw new fail('IllegalArgumentException: no enum constant org.jsoup.Connection.Method.' + value);
    });
    freeze(jsoupMethods);
    function jsoupWireMethod(value) {
      value = jsoupString(value, 'host method', true);
      for (var i = 0; i < jsoupMethodValues.length; i++) {
        if (jsoupPrivateGet(jsoupMethodValues[i]).name === value) return jsoupMethodValues[i];
      }
      throw new fail('Invalid Jsoup host response method: ' + value);
    }
    function jsoupUrl(value) {
      value = jsoupString(value, 'URL', true);
      // Native URL normalization and IDN handling belong to the HTTP host, not a second JS URL parser.
      if (!jsoupTest(/^https?:\/\//i, value) || jsoupTest(/[\x00-\x1f\x7f]/, value)) {
        throw new fail('MalformedURLException: Jsoup requires an absolute HTTP(S) URL');
      }
      var start = stringIndex(value, '://') + 3, end = value.length;
      for (var i = start; i < value.length; i++) {
        var c = charAt(value, i);
        if (c === '/' || c === '?' || c === '#') { end = i; break; }
      }
      var authority = stringSlice(value, start, end), at = stringLastIndex(authority, '@');
      var host = stringSlice(authority, at + 1);
      if (!host.length || jsoupTest(/[\s\\]/, host)) throw new fail('MalformedURLException: invalid Jsoup URL host');
      var portAt = stringLastIndex(host, ':');
      if (charAt(host, 0) === '[') {
        var close = stringIndex(host, ']');
        if (close < 2 || close + 1 < host.length && charAt(host, close + 1) !== ':') {
          throw new fail('MalformedURLException: invalid IPv6 URL host');
        }
        portAt = close + 1 < host.length ? close + 1 : -1;
      } else if (portAt === 0 || portAt >= 0 && stringIndex(host, ':') !== portAt) {
        throw new fail('MalformedURLException: invalid URL host');
      }
      if (portAt >= 0) {
        var port = stringSlice(host, portAt + 1);
        if (!jsoupTest(/^[0-9]+$/, port) || number(port) > 65535) throw new fail('MalformedURLException: invalid URL port');
      }
      return value;
    }
    function jsoupCharset(value) {
      value = jsoupString(value, 'charset', true);
      // Reuse the bridge's codec whitelist; do not silently accept a platform UTF-8 fallback.
      jsoupCodecName(value);
      return value;
    }
    function jsoupCodecName(value) {
      var name = upper(value);
      if (name === 'SHIFT_JIS' || name === 'SHIFT-JIS' || name === 'SJIS') return 'SHIFT_JIS';
      if (name === 'EUC-JP' || name === 'EUCJP') return 'EUC-JP';
      return formCharset([null, value], 'Jsoup charset');
    }
    function jsoupDeclaredCharset(value) {
      if (value === null) return null;
      value = join(split(join(split(trim(value), '"'), ''), "'"), '');
      if (!value.length) return null;
      try { jsoupCodecName(value); return value; }
      catch (unsupportedCharset) { return null; }
    }
    function jsoupContentCharset(contentType) {
      if (contentType === null) return null;
      var match = jsoupRegexExec(/\bcharset=\s*["']?([^\s,;"']*)/i, contentType);
      return match ? jsoupDeclaredCharset(match[1]) : null;
    }
    function jsoupOutputCharset(value) {
      var codec = jsoupCodecName(value);
      return codec === 'ASCII' ? 'US-ASCII' : codec === 'SHIFT_JIS' ? 'Shift_JIS' : codec === 'BIG5' ? 'Big5' : codec;
    }
    function jsoupDecodeBytes(bytes, charset) {
      var codec = jsoupCodecName(charset);
      function decode(part, name) {
        var decoded = parse(jsoupHostDecodeBytes(stringify(jsoupJsonCopy(part, 0)), name));
        if (typeof decoded !== 'string') throw new fail('Invalid Jsoup decoded text response');
        return decoded;
      }
      if (codec === 'UTF-8') return decode(bytes, null);
      if (codec === 'SHIFT_JIS' || codec === 'EUC-JP') return decode(bytes, codec);
      if (stringIndex(codec, 'UTF-16') === 0) return formDecodeUtf16(bytes, codec);
      if (codec === 'ASCII' || codec === 'ISO-8859-1') return formDecodeBytes(bytes, codec);
      var output = '';
      for (var i = 0; i < bytes.length;) {
        if (bytes[i] < 128) { output += fromCharCode(bytes[i++]); continue; }
        var count = legacyFormUnit(bytes, i, codec);
        if (!count) { output += fromCharCode(65533); i++; continue; }
        var part = slice(bytes, i, i + count);
        var decoded = decode(part, codec);
        output += sameFormBytes(part, byteArray(strToBytes(decoded, codec))) ? decoded : fromCharCode(65533);
        i += count;
      }
      return output;
    }
    function jsoupMap() {
      var target = new jsoupMapCtor();
      metadata(target).items = jsoupArray();
      return target;
    }
    function jsoupList(items, readOnly) {
      var target = new jsoupListCtor(), data = metadata(target);
      data.items = jsoupArray(); data.readOnly = !!readOnly;
      for (var i = 0; items && i < items.length; i++) jsoupAppend(data.items, items[i]);
      return target;
    }
    function jsoupPut(map, key, value) {
      var data = metadata(map), at = find(data.items, key, true);
      if (at < 0) { jsoupAppend(data.items, [key, value]); changed(data); }
      else data.items[at][1] = value;
    }
    function jsoupRemove(map, key) {
      var data = metadata(map), at = find(data.items, key, true);
      if (at >= 0) { splice(data.items, at, 1); changed(data); }
    }
    function jsoupMapItems(map) {
      var data = metadata(map);
      if (!data || data.kind !== 'map') throw new fail('Expected a Java Map');
      return data.items;
    }
    function jsoupListItems(list) {
      var data = metadata(list);
      if (!data || data.kind !== 'list') throw new fail('Expected a Java List for Jsoup header values');
      return data.items;
    }
    function jsoupHeaderValue(value) { return value === null ? '' : jsoupString(value, 'header value', false); }
    function jsoupHeaderEntry(headers, name) {
      var items = jsoupMapItems(headers), wanted = lower(name);
      for (var i = 0; i < items.length; i++) {
        if (lower(jsoupString(items[i][0], 'header name', true)) === wanted) return items[i];
      }
      return null;
    }
    function jsoupHeaderList(headers, name) {
      var entry = jsoupHeaderEntry(headers, name);
      return entry ? entry[1] : jsoupList(null, true);
    }
    function jsoupHeaderRead(headers, name) {
      var entry = jsoupHeaderEntry(headers, name);
      if (!entry) return null;
      var values = jsoupListItems(entry[1]), result = '';
      for (var i = 0; i < values.length; i++) result += (i ? ', ' : '') + jsoupHeaderValue(values[i]);
      return values.length ? result : null;
    }
    function jsoupHeaderSet(headers, name, value, append) {
      name = jsoupString(name, 'header name', true); value = jsoupHeaderValue(value);
      var entry = jsoupHeaderEntry(headers, name);
      if (append && entry && jsoupListItems(entry[1]).length) {
        var listData = metadata(entry[1]); jsoupAppend(listData.items, value); changed(listData);
      } else {
        if (!append && entry) jsoupRemove(headers, entry[0]);
        jsoupPut(headers, name, jsoupList([value], false));
      }
    }
    function jsoupFirstHeaders(headers) {
      var result = jsoupMap(), items = jsoupMapItems(headers);
      for (var i = 0; i < items.length; i++) {
        var values = jsoupListItems(items[i][1]);
        if (values.length) jsoupPut(result, jsoupString(items[i][0], 'header name', true), jsoupHeaderValue(values[0]));
      }
      return result;
    }
    function jsoupCopyHeaders(headers) {
      var output = jsoupMap(), items = jsoupMapItems(headers);
      for (var i = 0; i < items.length; i++) {
        var values = jsoupListItems(items[i][1]), copy = jsoupArray();
        for (var j = 0; j < values.length; j++) jsoupAppend(copy, jsoupHeaderValue(values[j]));
        jsoupPut(output, jsoupString(items[i][0], 'header name', true), jsoupList(copy, false));
      }
      return output;
    }
    function jsoupStringPairs(value, label, headers) {
      var input = mapPairs(value), result = jsoupArray();
      for (var i = 0; i < input.length; i++) {
        jsoupAppend(result, [jsoupString(input[i][0], label + ' key', true),
          headers ? jsoupHeaderValue(input[i][1]) : jsoupString(input[i][1], label + ' value', false)]);
      }
      return result;
    }
    function jsoupStringMapCopy(value, label) {
      var result = jsoupMap(), items = jsoupStringPairs(value, label, false);
      for (var i = 0; i < items.length; i++) jsoupPut(result, items[i][0], items[i][1]);
      return result;
    }
    function jsoupStringObject(map, label) {
      var result = create(null), items = jsoupStringPairs(map, label, false);
      for (var i = 0; i < items.length; i++) field(result, items[i][0], items[i][1]);
      return result;
    }
    function jsoupKeyVal(key, value) {
      var data = create(null), target = create(null);
      data.kind = 'keyval'; data.key = jsoupString(key, 'data key', true); data.value = jsoupString(value, 'data value', false);
      jsoupPrivateSet(target, data);
      method(target, 'key', function(value) {
        arity(arguments, 0, 1, 'KeyVal.key');
        if (!arguments.length) return jsoupStringCtor(data.key);
        data.key = jsoupString(value, 'data key', true); return target;
      });
      method(target, 'value', function(value) {
        arity(arguments, 0, 1, 'KeyVal.value');
        if (!arguments.length) return jsoupStringCtor(data.value);
        data.value = jsoupString(value, 'data value', false); return target;
      });
      method(target, 'hasInputStream', function() { arity(arguments, 0, 0, 'KeyVal.hasInputStream'); return false; });
      method(target, 'toString', function() { arity(arguments, 0, 0, 'KeyVal.toString'); return data.key + '=' + data.value; });
      jsoupReject(target, 'Connection.KeyVal', ['inputStream', 'contentType']);
      return target;
    }
    function jsoupAddData(state, args, request) {
      var destination = metadata(state.data);
      function append(value) {
        jsoupPrivateData(value, 'keyval'); jsoupAppend(destination.items, value); changed(destination);
      }
      if (request) {
        arity(args, 1, 1, 'Request.data'); append(args[0]);
      } else if (args.length === 1 && typeof unbox(args[0]) === 'string') {
        var key = jsoupString(args[0], 'data key', true), items = jsoupListItems(state.data);
        for (var i = 0; i < items.length; i++) if (jsoupPrivateData(items[i], 'keyval').key === key) return items[i];
        return null;
      } else {
        var data = args.length === 1 ? metadata(args[0]) : null;
        var collection = data && (data.kind === 'list' || data.kind === 'set' || data.kind === 'view');
        if (collection) {
          var items = valuesOf(args[0]);
          for (var i = 0; i < items.length; i++) append(items[i]);
        } else if (args.length === 1 && !isArray(args[0])) {
          var pairs = mapPairs(args[0]);
          for (var i = 0; i < pairs.length; i++) append(jsoupKeyVal(pairs[i][0], pairs[i][1]));
        } else {
          var items = args.length === 1 ? valuesOf(args[0]) : args;
          var first = args.length === 1 && items.length ? jsoupPrivateGet(items[0]) : null;
          if (first && first.kind === 'keyval') {
            for (var i = 0; i < items.length; i++) append(items[i]);
            return undefined;
          }
          if (items.length % 2) throw new fail('IllegalArgumentException: data requires an even number of key/value strings; streams are unsupported');
          for (var i = 0; i < items.length; i += 2) append(jsoupKeyVal(items[i], items[i + 1]));
        }
      }
      return undefined;
    }
    function jsoupSerialiseRequestUrl(state) {
      var url = jsoupRequiredUrl(state), hash = stringIndex(url, '#');
      var head = hash < 0 ? url : stringSlice(url, 0, hash), fragment = hash < 0 ? '' : stringSlice(url, hash);
      var query = '', items = jsoupListItems(state.data);
      for (var i = 0; i < items.length; i++) {
        var data = jsoupPrivateData(items[i], 'keyval');
        query += (i ? '&' : '') + unbox(jsoupFormEncode(data.key, 'UTF-8')) + '=' + unbox(jsoupFormEncode(data.value, 'UTF-8'));
      }
      state.url = head + (stringIndex(head, '?') < 0 ? '?' : '&') + query + fragment;
      if (items.length) { items.length = 0; changed(metadata(state.data)); }
    }
    function jsoupJsonCopy(value, depth) {
      if (depth > 64) throw new fail('Jsoup host JSON exceeds the supported nesting depth');
      if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
      if (typeof value === 'number' && finite(value)) return value;
      if (!value || typeof value !== 'object') throw new fail('Invalid Jsoup host JSON value');
      var output = isArray(value) ? jsoupArray() : create(null), names = keys(value);
      for (var i = 0; i < names.length; i++) field(output, names[i], jsoupJsonCopy(value[names[i]], depth + 1));
      return output;
    }
""".trimIndent()
