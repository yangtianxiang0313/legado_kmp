package io.legado.kmp.shared.scripting

internal val LEGACY_JS_JAVA_JSOUP_RESPONSE = """
    function jsoupHostField(value, name) {
      if (!own(value, name)) throw new fail('Invalid Jsoup host response: missing ' + name);
      return value[name];
    }
    function jsoupHostObject(value, label) {
      if (value === null || typeof value !== 'object' || isArray(value)) {
        throw new fail('Invalid Jsoup host response: ' + label + ' must be an object');
      }
      return value;
    }
    function jsoupHostHeaders(value, firstHeaders) {
      jsoupHostObject(value, 'allHeaders'); jsoupHostObject(firstHeaders, 'headers');
      var result = jsoupMap(), names = keys(value);
      for (var i = 0; i < names.length; i++) {
        var name = jsoupString(names[i], 'host header name', true), values = value[name];
        if (!isArray(values)) throw new fail('Invalid Jsoup host response: allHeaders values must be arrays');
        var copied = jsoupArray();
        for (var j = 0; j < values.length; j++) jsoupAppend(copied, jsoupString(values[j], 'host header value', false));
        if (jsoupHeaderEntry(result, name)) throw new fail('Invalid Jsoup host response: duplicate case-insensitive header name');
        jsoupPut(result, name, jsoupList(copied, false));
      }
      // allHeaders is authoritative, including order and repeated Set-Cookie fields.
      var firstPairs = jsoupStringPairs(firstHeaders, 'host header', false);
      for (var i = 0; i < firstPairs.length; i++) {
        if (!jsoupHeaderEntry(result, firstPairs[i][0])) {
          throw new fail('Invalid Jsoup host response: headers entry missing from allHeaders');
        }
      }
      return result;
    }
    function jsoupHostBytes(value) {
      value = jsoupString(value, 'bodyBase64', false);
      if (value.length % 4 || !jsoupTest(/^(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?$/, value)) {
        throw new fail('Invalid Jsoup host response: malformed bodyBase64');
      }
      if (!value.length) return jsoupArray();
      var raw = byteArray(base64DecodeBytes(value)), signed = jsoupArray();
      for (var i = 0; i < raw.length; i++) jsoupAppend(signed, raw[i] >= 128 ? raw[i] - 256 : raw[i]);
      return signed;
    }
    function jsoupCheckResponse(state, request) {
      if (!request.ignoreHttpErrors && (state.statusCode < 200 || state.statusCode >= 400)) {
        throw new error('HttpStatusException: HTTP error fetching URL. Status=' + state.statusCode + ', URL=' + state.url);
      }
      if (!request.ignoreContentType && state.contentType !== null &&
          stringIndex(state.contentType, 'text/') !== 0 && !jsoupTest(/^(application|text)\/\w*\+?xml.*$/, state.contentType)) {
        throw new error('UnsupportedMimeTypeException: unhandled content type ' + state.contentType + ', URL=' + state.url);
      }
    }
    function jsoupResponse(value, request) {
      jsoupHostObject(value, 'response');
      var state = create(null), target = create(null);
      state.kind = 'response'; state.url = jsoupUrl(jsoupHostField(value, 'url'));
      state.method = jsoupWireMethod(jsoupHostField(value, 'method'));
      state.hadRedirectToGet = jsoupBoolean(jsoupHostField(value, 'hadRedirectToGet'), 'host hadRedirectToGet');
      state.statusCode = jsoupInt(jsoupHostField(value, 'statusCode'), 'host statusCode');
      if (state.statusCode < 100 || state.statusCode > 999) throw new fail('Invalid Jsoup host response: statusCode outside HTTP range');
      state.statusMessage = jsoupString(jsoupHostField(value, 'statusMessage'), 'host statusMessage', false);
      state.headers = jsoupHostHeaders(jsoupHostField(value, 'allHeaders'), jsoupHostField(value, 'headers'));
      state.cookies = jsoupStringMapCopy(jsoupHostObject(jsoupHostField(value, 'cookies'), 'cookies'), 'host cookie');
      var cookieStore = jsoupHostField(value, 'cookieStore');
      if (!isArray(cookieStore)) throw new fail('Invalid Jsoup host response: cookieStore must be an array');
      state.cookieStore = jsoupJsonCopy(cookieStore, 0);
      state.hostBodyText = jsoupString(jsoupHostField(value, 'bodyText'), 'host bodyText', false);
      state.bytes = jsoupHostBytes(jsoupHostField(value, 'bodyBase64'));
      if (state.method === jsoupMethods.HEAD && state.bytes.length) {
        throw new fail('Invalid Jsoup host response: HEAD must not contain a response body');
      }
      if (request.maxBodySize && state.bytes.length > request.maxBodySize) {
        throw new fail('Invalid Jsoup host response: host exceeded maxBodySize');
      }
      var charset = jsoupHostField(value, 'charset'), contentType = jsoupHostField(value, 'contentType');
      state.detectedCharset = charset === null ? null : jsoupString(charset, 'host charset', true);
      state.detectedBytes = byteArray(state.bytes);
      state.contentType = contentType === null ? null : jsoupString(contentType, 'host contentType', false);
      // execute() exposes only the HTTP charset; BOM / meta detection happens on parse(), not body().
      state.headerCharset = jsoupContentCharset(state.contentType); state.charset = state.headerCharset;
      state.bodyRead = false; state.request = request;
      // The host eagerly transfers bytes; retain Jsoup's observable stream-consumption rules.
      var length = jsoupHeaderRead(state.headers, 'Content-Length');
      state.buffered = state.method === jsoupMethods.HEAD || length !== null && jsoupTest(/^\+?0+$/, trim(length));
      jsoupPrivateSet(target, state);
      jsoupResponseMethods(target, state);
      return target;
    }
    function jsoupReadBody(state, parsing) {
      if (state.bodyRead && !state.buffered) throw new fail('IllegalArgumentException: response has already been read with parse()');
      if (!parsing && !state.buffered) {
        // prepareByteData() reads the current Request limit in addition to the original stream's limit.
        var limit = state.request.maxBodySize;
        if (limit && state.bytes.length > limit) state.bytes.length = limit;
        state.buffered = true; state.bodyRead = true;
      }
    }
    function jsoupReusableBodyText(state, bytes, charset, parsingBom) {
      if (state.detectedCharset === null || !sameFormBytes(bytes, state.detectedBytes)) return null;
      var codec, hostCodec;
      try { codec = jsoupCodecName(charset); hostCodec = jsoupCodecName(state.detectedCharset); }
      catch (unsupportedCodec) { return null; }
      if (bytes.length >= 4 && (bytes[0] === 0 && bytes[1] === 0 && bytes[2] === 254 && bytes[3] === 255 ||
          bytes[0] === 255 && bytes[1] === 254 && bytes[2] === 0 && bytes[3] === 0)) return null;
      var utf8Bom = bytes.length >= 3 && bytes[0] === 239 && bytes[1] === 187 && bytes[2] === 191;
      var utf16Bom = bytes.length >= 2 && (bytes[0] === 254 && bytes[1] === 255 || bytes[0] === 255 && bytes[1] === 254);
      // The host strips BOMs, but body() is a charset decode, not a BOM-detecting parse.
      if ((utf8Bom || utf16Bom) && !parsingBom) return null;
      if (utf8Bom && codec !== 'UTF-8') return null;
      if (utf16Bom) {
        if (codec !== 'UTF-16') return null;
        var endianCodec = bytes[0] === 254 ? 'UTF-16BE' : 'UTF-16LE';
        if (hostCodec !== 'UTF-16' && hostCodec !== endianCodec) return null;
      } else if (codec !== hostCodec) return null;
      return state.hostBodyText;
    }
    function jsoupBodyText(state) {
      var bytes = byteArray(state.bytes), charset = state.charset === null ? 'UTF-8' : state.charset;
      var reused = jsoupReusableBodyText(state, bytes, charset, false);
      return reused === null ? jsoupDecodeBytes(bytes, charset) : reused;
    }
    function jsoupParseDocument(html, url) {
      var payload = parseHtml(html, url);
      if (typeof payload !== 'string') throw new fail('Invalid DOM host response while parsing Jsoup response');
      var raw = parse(payload);
      if (raw === null || typeof raw !== 'object' || isArray(raw) || !own(raw, 'outerHtml')) {
        throw new fail('Invalid DOM host document while parsing Jsoup response');
      }
      return raw;
    }
    function jsoupMetaCharset(raw) {
      // Reuse the registered native DOM selector, not a JS HTML parser or a regex over HTML.
      var metas = parse(selectHtml(stringify(jsoupJsonCopy(raw, 0)), 'meta[http-equiv=content-type], meta[charset]'));
      if (!isArray(metas)) throw new fail('Invalid DOM host meta selection while parsing Jsoup response');
      for (var i = 0; i < metas.length; i++) {
        var meta = metas[i], attrs = meta && own(meta, 'attrs') ? meta.attrs : null, found = null;
        if (!attrs || typeof attrs !== 'object') throw new fail('Invalid DOM host meta attributes');
        if (own(attrs, 'http-equiv') && own(attrs, 'content')) {
          found = jsoupContentCharset(jsoupString(attrs.content, 'meta content', false));
        }
        if (found === null && own(attrs, 'charset')) found = jsoupString(attrs.charset, 'meta charset', false);
        if (found !== null) {
          // A declared but invalid HTML5 charset terminates the scan in DataUtil, too.
          return jsoupDeclaredCharset(found) || false;
        }
      }
      return null;
    }
    function jsoupParseResponse(state) {
      jsoupReadBody(state, true);
      var bytes = byteArray(state.bytes), charset = state.charset, raw = null, bom = false;
      if (bytes.length >= 4 && (bytes[0] === 0 && bytes[1] === 0 && bytes[2] === 254 && bytes[3] === 255 ||
          bytes[0] === 255 && bytes[1] === 254 && bytes[2] === 0 && bytes[3] === 0)) {
        throw new fail('UnsupportedEncodingException: UTF-32 response BOM is not supported by the shared text codec');
      }
      // 1.16.2's detectCharsetFromBom reads its four-byte probe only when all four bytes are present.
      if (bytes.length >= 4 && (bytes[0] === 254 && bytes[1] === 255 || bytes[0] === 255 && bytes[1] === 254)) {
        charset = 'UTF-16'; bom = true;
      } else if (bytes.length >= 4 && bytes[0] === 239 && bytes[1] === 187 && bytes[2] === 191) {
        charset = 'UTF-8'; bom = true;
      }
      if (charset === null) {
        var sample = bytes.length > 5119 ? slice(bytes, 0, 5119) : bytes;
        raw = jsoupParseDocument(jsoupDecodeBytes(sample, 'UTF-8'), state.url);
        charset = jsoupMetaCharset(raw);
        if (charset === false) charset = 'UTF-8';
        if (charset === null && state.headerCharset === null && state.detectedCharset !== null &&
            sameFormBytes(bytes, state.detectedBytes)) {
          charset = jsoupDeclaredCharset(state.detectedCharset);
        }
        if (charset === null) charset = 'UTF-8';
        if (jsoupCodecName(charset) !== 'UTF-8' || sample.length !== bytes.length) raw = null;
      }
      if (raw === null) {
        var html = jsoupReusableBodyText(state, bytes, charset, bom);
        if (html === null) {
          html = jsoupDecodeBytes(bytes, charset);
          if (bom && charset === 'UTF-8' && charCodeAt(html, 0) === 65279) html = stringSlice(html, 1);
        }
        raw = jsoupParseDocument(html, state.url);
      }
      state.bodyRead = true;
      state.charset = jsoupOutputCharset(charset);
      return element(raw);
    }
    function jsoupResponseMethods(target, state) {
      var getState = function() { return state; };
      method(target, 'parse', function() { arity(arguments, 0, 0, 'Response.parse'); return jsoupParseResponse(state); });
      method(target, 'body', function() {
        arity(arguments, 0, 0, 'Response.body'); jsoupReadBody(state, false); return jsoupStringCtor(jsoupBodyText(state));
      });
      method(target, 'bodyAsBytes', function() {
        arity(arguments, 0, 0, 'Response.bodyAsBytes'); jsoupReadBody(state, false); return state.bytes;
      });
      method(target, 'bufferUp', function() {
        arity(arguments, 0, 0, 'Response.bufferUp');
        if (state.buffered || !state.bodyRead) jsoupReadBody(state, false);
        return target;
      });
      method(target, 'statusCode', function() { arity(arguments, 0, 0, 'Response.statusCode'); return state.statusCode; });
      method(target, 'statusMessage', function() { arity(arguments, 0, 0, 'Response.statusMessage'); return jsoupStringCtor(state.statusMessage); });
      method(target, 'url', function(value) {
        arity(arguments, 0, 1, 'Response.url');
        if (!arguments.length) return jsoupStringCtor(state.url);
        state.url = jsoupUrl(value); return target;
      });
      method(target, 'method', function(value) {
        arity(arguments, 0, 1, 'Response.method');
        if (!arguments.length) return state.method;
        jsoupPrivateData(value, 'method'); state.method = value; return target;
      });
      method(target, 'charset', function(value) {
        arity(arguments, 0, 1, 'Response.charset');
        if (!arguments.length) return state.charset === null ? null : jsoupStringCtor(state.charset);
        state.charset = value === null ? null : jsoupString(value, 'response charset', false); return target;
      });
      method(target, 'contentType', function() {
        arity(arguments, 0, 0, 'Response.contentType'); return state.contentType === null ? null : jsoupStringCtor(state.contentType);
      });
      method(target, 'header', function(name, value) {
        arity(arguments, 1, 2, 'Response.header'); name = jsoupString(name, 'header name', arguments.length === 2);
        if (arguments.length === 2) { jsoupHeaderSet(state.headers, name, value, false); return target; }
        var result = jsoupHeaderRead(state.headers, name); return result === null ? null : jsoupStringCtor(result);
      });
      method(target, 'headers', function(name) {
        arity(arguments, 0, 1, 'Response.headers');
        return arguments.length ? jsoupHeaderList(state.headers, jsoupString(name, 'header name', true)) : jsoupFirstHeaders(state.headers);
      });
      jsoupHeaderQueries(target, getState); jsoupCookieOptions(target, getState, true);
      jsoupReject(target, 'Connection.Response', ['bodyStream', 'parser', 'sslSocketFactory', 'proxy']);
    }
""".trimIndent()
