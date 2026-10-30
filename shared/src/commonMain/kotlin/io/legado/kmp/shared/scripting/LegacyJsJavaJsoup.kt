package io.legado.kmp.shared.scripting

// Insert after LEGACY_JS_JAVA_URL in javaInterop. The caller registers JJsoupConnection.
internal val LEGACY_JS_JAVA_JSOUP = """
    $LEGACY_JS_JAVA_JSOUP_SUPPORT
    $LEGACY_JS_JAVA_JSOUP_RESPONSE

    function JJsoupConnection() {
      throw new fail('UnsupportedOperationException: create a Connection with Jsoup.connect or Jsoup.newSession');
    }
    JJsoupConnection.prototype = create(null);
    field(JJsoupConnection, 'Method', jsoupMethods);
    freeze(JJsoupConnection);
    field(org.jsoup, 'Connection', JJsoupConnection);

    function jsoupRequestState(copy) {
      var state = create(null);
      state.kind = 'request'; state.url = copy ? copy.url : null;
      state.method = copy ? copy.method : jsoupMethods.GET;
      state.headers = copy ? jsoupCopyHeaders(copy.headers) : jsoupMap();
      state.cookies = copy ? jsoupStringMapCopy(copy.cookies, 'cookie') : jsoupMap();
      state.data = jsoupList(null, false); state.requestBody = null;
      state.timeoutMillis = copy ? copy.timeoutMillis : 30000;
      state.maxBodySize = copy ? copy.maxBodySize : 2097152;
      state.followRedirects = copy ? copy.followRedirects : true;
      state.ignoreHttpErrors = copy ? copy.ignoreHttpErrors : false;
      state.ignoreContentType = copy ? copy.ignoreContentType : false;
      state.postDataCharset = copy ? copy.postDataCharset : 'UTF-8';
      state.cookieStore = copy ? copy.cookieStore : create(null);
      if (!copy) {
        state.cookieStore.items = jsoupArray();
        jsoupHeaderSet(state.headers, 'Accept-Encoding', 'gzip', false);
        jsoupHeaderSet(state.headers, 'User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/79.0.3945.130 Safari/537.36', false);
      }
      state.view = null; state.executing = false;
      return state;
    }
    function jsoupRequiredUrl(state) {
      if (state.url === null) throw new fail('IllegalArgumentException: URL not set; call url(...) before executing the request');
      return state.url;
    }
    function jsoupScalarOption(target, getState, name, key, validate, request) {
      method(target, name, function(value) {
        arity(arguments, request ? 0 : 1, 1, (request ? 'Request.' : 'Connection.') + name);
        var state = getState();
        if (!arguments.length) return key === 'postDataCharset' ? jsoupStringCtor(state[key]) : state[key];
        state[key] = validate(value, name); return target;
      });
    }
    function jsoupBaseOptions(target, getState, request) {
      method(target, 'url', function(value) {
        arity(arguments, request ? 0 : 1, 1, 'Jsoup.url');
        var state = getState();
        if (!arguments.length) return jsoupStringCtor(jsoupRequiredUrl(state));
        state.url = jsoupUrl(value); return target;
      });
      method(target, 'method', function(value) {
        arity(arguments, request ? 0 : 1, 1, 'Jsoup.method');
        var state = getState();
        if (!arguments.length) return state.method;
        jsoupPrivateData(value, 'method'); state.method = value; return target;
      });
      jsoupScalarOption(target, getState, 'timeout', 'timeoutMillis', jsoupInt, request);
      jsoupScalarOption(target, getState, 'maxBodySize', 'maxBodySize', jsoupInt, request);
      jsoupScalarOption(target, getState, 'followRedirects', 'followRedirects', jsoupBoolean, request);
      jsoupScalarOption(target, getState, 'ignoreHttpErrors', 'ignoreHttpErrors', jsoupBoolean, request);
      jsoupScalarOption(target, getState, 'ignoreContentType', 'ignoreContentType', jsoupBoolean, request);
      jsoupScalarOption(target, getState, 'postDataCharset', 'postDataCharset', jsoupCharset, request);
      method(target, 'requestBody', function(value) {
        arity(arguments, request ? 0 : 1, 1, 'Jsoup.requestBody');
        var state = getState();
        if (!arguments.length) return state.requestBody === null ? null : jsoupStringCtor(state.requestBody);
        state.requestBody = value === null ? null : jsoupString(value, 'request body', false); return target;
      });
      method(target, 'data', function() {
        var state = getState();
        if (request && !arguments.length) return state.data;
        var result = jsoupAddData(state, arguments, request);
        return result === undefined ? target : result;
      });
      jsoupHeaderOptions(target, getState, request);
      jsoupCookieOptions(target, getState, request);
      jsoupReject(target, request ? 'Connection.Request' : 'Connection',
        ['proxy', 'sslSocketFactory', 'parser', 'bodyStream', 'cookieStore', 'validateTLSCertificates', 'authenticator']);
    }
    function jsoupHeaderOptions(target, getState, request) {
      method(target, 'header', function(name, value) {
        arity(arguments, request ? 1 : 2, 2, 'Jsoup.header');
        name = jsoupString(name, 'header name', arguments.length === 2);
        if (arguments.length === 1) {
          var result = jsoupHeaderRead(getState().headers, name);
          return result === null ? null : jsoupStringCtor(result);
        }
        jsoupHeaderSet(getState().headers, name, value, false); return target;
      });
      method(target, 'headers', function(value) {
        arity(arguments, request ? 0 : 1, 1, 'Jsoup.headers');
        var state = getState();
        if (request) {
          if (!arguments.length) return jsoupFirstHeaders(state.headers);
          return jsoupHeaderList(state.headers, jsoupString(value, 'header name', true));
        }
        var pairs = mapPairs(value);
        for (var i = 0; i < pairs.length; i++) jsoupHeaderSet(state.headers, pairs[i][0], pairs[i][1], false);
        return target;
      });
      if (!request) {
        method(target, 'userAgent', function(value) {
          arity(arguments, 1, 1, 'Connection.userAgent');
          jsoupHeaderSet(getState().headers, 'User-Agent', jsoupString(value, 'userAgent', false), false); return target;
        });
        method(target, 'referrer', function(value) {
          arity(arguments, 1, 1, 'Connection.referrer');
          jsoupHeaderSet(getState().headers, 'Referer', jsoupString(value, 'referrer', false), false); return target;
        });
      } else jsoupHeaderQueries(target, getState);
    }
    function jsoupHeaderQueries(target, getState) {
      method(target, 'multiHeaders', function() { arity(arguments, 0, 0, 'Jsoup.multiHeaders'); return getState().headers; });
      method(target, 'addHeader', function(name, value) {
        arity(arguments, 2, 2, 'Jsoup.addHeader'); jsoupHeaderSet(getState().headers, name, value, true); return target;
      });
      method(target, 'removeHeader', function(name) {
        arity(arguments, 1, 1, 'Jsoup.removeHeader'); name = jsoupString(name, 'header name', true);
        var headers = getState().headers, entry = jsoupHeaderEntry(headers, name);
        if (entry) jsoupRemove(headers, entry[0]);
        return target;
      });
      method(target, 'hasHeader', function(name) {
        arity(arguments, 1, 1, 'Jsoup.hasHeader');
        return jsoupHeaderRead(getState().headers, jsoupString(name, 'header name', true)) !== null;
      });
      method(target, 'hasHeaderWithValue', function(name, value) {
        arity(arguments, 2, 2, 'Jsoup.hasHeaderWithValue');
        name = jsoupString(name, 'header name', true); value = lower(jsoupString(value, 'header value', true));
        var entry = jsoupHeaderEntry(getState().headers, name);
        if (!entry) return false;
        var values = jsoupListItems(entry[1]);
        for (var i = 0; i < values.length; i++) if (lower(jsoupHeaderValue(values[i])) === value) return true;
        return false;
      });
    }
    function jsoupCookieOptions(target, getState, request) {
      method(target, 'cookie', function(name, value) {
        arity(arguments, request ? 1 : 2, 2, 'Jsoup.cookie'); name = jsoupString(name, 'cookie name', true);
        var cookies = getState().cookies;
        if (arguments.length === 1) {
          var at = find(jsoupMapItems(cookies), name, true);
          return at < 0 ? null : jsoupStringCtor(jsoupString(jsoupMapItems(cookies)[at][1], 'cookie value', false));
        }
        jsoupPut(cookies, name, jsoupString(value, 'cookie value', false)); return target;
      });
      method(target, 'cookies', function(value) {
        arity(arguments, request ? 0 : 1, request ? 0 : 1, 'Jsoup.cookies');
        var cookies = getState().cookies;
        if (request) return cookies;
        var pairs = mapPairs(value);
        for (var i = 0; i < pairs.length; i++) {
          jsoupPut(cookies, jsoupString(pairs[i][0], 'cookie name', true), jsoupString(pairs[i][1], 'cookie value', false));
        }
        return target;
      });
      if (request) {
        method(target, 'hasCookie', function(name) {
          arity(arguments, 1, 1, 'Jsoup.hasCookie');
          return find(jsoupMapItems(getState().cookies), jsoupString(name, 'cookie name', true), true) >= 0;
        });
        method(target, 'removeCookie', function(name) {
          arity(arguments, 1, 1, 'Jsoup.removeCookie');
          jsoupRemove(getState().cookies, jsoupString(name, 'cookie name', true)); return target;
        });
      }
    }
    function jsoupRequestView(state) {
      if (state.view !== null) return state.view;
      var target = create(null);
      jsoupPrivateSet(target, state); jsoupBaseOptions(target, function() { return state; }, true);
      state.view = target;
      return target;
    }
    function jsoupRequestPayload(state) {
      var payload = create(null), headers = create(null), headerPairs = jsoupMapItems(state.headers);
      payload.url = jsoupRequiredUrl(state); payload.method = jsoupPrivateData(state.method, 'method').name;
      for (var i = 0; i < headerPairs.length; i++) {
        var name = jsoupString(headerPairs[i][0], 'header name', true), values = jsoupListItems(headerPairs[i][1]);
        // The wire contract has one value per request header: refuse a lossy multi-value conversion.
        if (values.length > 1) throw new fail('UnsupportedOperationException: multiple request header values cannot cross the Jsoup host contract');
        if (values.length) field(headers, name, jsoupHeaderValue(values[0]));
      }
      payload.headers = headers; payload.cookies = jsoupStringObject(state.cookies, 'cookie');
      payload.data = jsoupArray();
      var items = jsoupListItems(state.data);
      for (var i = 0; i < items.length; i++) {
        var keyval = jsoupPrivateData(items[i], 'keyval'), pair = jsoupArray();
        jsoupAppend(pair, keyval.key); jsoupAppend(pair, keyval.value); jsoupAppend(payload.data, pair);
      }
      payload.requestBody = state.requestBody;
      payload.timeoutMillis = state.timeoutMillis; payload.maxBodySize = state.maxBodySize;
      payload.followRedirects = state.followRedirects; payload.ignoreHttpErrors = state.ignoreHttpErrors;
      payload.ignoreContentType = state.ignoreContentType; payload.postDataCharset = jsoupCodecName(state.postDataCharset);
      payload.cookieStore = jsoupJsonCopy(state.cookieStore.items, 0);
      return payload;
    }
    function jsoupExecute(state) {
      if (jsoupHostExecute === null) throw new fail('UnsupportedOperationException: __legacyJsoupExecute host is not available');
      if (state.executing) throw new fail('IllegalStateException: Jsoup request is already executing; use newRequest()');
      jsoupRequiredUrl(state);
      var methodData = jsoupPrivateData(state.method, 'method');
      if (!methodData.hasBody && state.requestBody !== null) {
        throw new fail('IllegalArgumentException: cannot set a request body for HTTP method ' + methodData.name);
      }
      var queryData = jsoupListItems(state.data).length > 0 && (!methodData.hasBody || state.requestBody !== null);
      if (queryData) jsoupSerialiseRequestUrl(state);
      else if (methodData.hasBody && jsoupHeaderRead(state.headers, 'Content-Type') === null) {
        jsoupHeaderSet(state.headers, 'Content-Type', 'application/x-www-form-urlencoded; charset=' + state.postDataCharset, false);
      }
      var payload = jsoupRequestPayload(state);
      state.executing = true;
      try {
        // No catch: host HTTP errors and cancellation must remain failures, never an empty DOM.
        var wire = jsoupHostExecute(stringify(payload));
        if (typeof wire !== 'string') throw new fail('Invalid Jsoup host response: expected a JSON string');
        var response = jsoupResponse(parse(wire), state);
        var responseData = jsoupPrivateGet(response);
        state.cookieStore.items = responseData.cookieStore;
        if (queryData || responseData.hadRedirectToGet) {
          var data = metadata(state.data);
          if (data.items.length) { data.items.length = 0; changed(data); }
        }
        if (responseData.hadRedirectToGet) {
          state.requestBody = null;
          var contentHeader = jsoupHeaderEntry(state.headers, 'Content-Type');
          if (contentHeader) jsoupRemove(state.headers, contentHeader[0]);
        }
        state.url = responseData.url; state.method = responseData.method;
        jsoupCheckResponse(responseData, state);
        return response;
      } finally { state.executing = false; }
    }
    function jsoupConnection(state) {
      var currentRequest = state, currentResponse = null, target = create(JJsoupConnection.prototype);
      jsoupBaseOptions(target, function() { return currentRequest; }, false);
      method(target, 'newRequest', function() {
        arity(arguments, 0, 0, 'Connection.newRequest'); return jsoupConnection(jsoupRequestState(currentRequest));
      });
      method(target, 'request', function(value) {
        arity(arguments, 0, 1, 'Connection.request');
        if (!arguments.length) return jsoupRequestView(currentRequest);
        currentRequest = jsoupPrivateData(value, 'request'); return target;
      });
      method(target, 'response', function(value) {
        arity(arguments, 0, 1, 'Connection.response');
        if (arguments.length) { jsoupPrivateData(value, 'response'); currentResponse = value; return target; }
        if (currentResponse === null) throw new fail('IllegalArgumentException: execute the request before getting a response');
        return currentResponse;
      });
      method(target, 'execute', function() {
        arity(arguments, 0, 0, 'Connection.execute');
        var response = jsoupExecute(currentRequest); currentResponse = response; return response;
      });
      method(target, 'get', function() {
        arity(arguments, 0, 0, 'Connection.get'); currentRequest.method = jsoupMethods.GET;
        var response = jsoupExecute(currentRequest); currentResponse = response; return jsoupParseResponse(jsoupPrivateGet(response));
      });
      method(target, 'post', function() {
        arity(arguments, 0, 0, 'Connection.post'); currentRequest.method = jsoupMethods.POST;
        var response = jsoupExecute(currentRequest); currentResponse = response; return jsoupParseResponse(jsoupPrivateGet(response));
      });
      return target;
    }
    method(org.jsoup.Jsoup, 'connect', function(url) {
      arity(arguments, 1, 1, 'Jsoup.connect');
      var state = jsoupRequestState(null); state.url = jsoupUrl(url); return jsoupConnection(state);
    });
    method(org.jsoup.Jsoup, 'newSession', function() {
      arity(arguments, 0, 0, 'Jsoup.newSession'); return jsoupConnection(jsoupRequestState(null));
    });
""".trimIndent()
