package io.legado.kmp.shared.scripting

internal val LEGACY_JS_JAVA_RAW_RESPONSE = """
    var jsoupRawConnect = typeof __legacyConnectRaw === 'function' ? __legacyConnectRaw : null;
    var jsoupRawPost = typeof __legacyPost === 'function' ? __legacyPost : null;

    function jsoupRawHeaderJson(value) {
      arity(arguments, 1, 1, 'raw headers');
      var data = metadata(value), headers = create(null);
      function add(name, content) {
        name = jsoupString(name, 'header name', true);
        field(headers, name, jsoupHeaderValue(content));
      }
      if (data) {
        if (data.kind !== 'map') throw new fail('Expected a supported Java Map for request headers');
        // Read the private entries, never the Map proxy's projected properties or toJSON().
        for (var i = 0; i < data.items.length; i++) add(data.items[i][0], data.items[i][1]);
      } else {
        if (value === null || typeof value !== 'object' || isArray(value) ||
            (prototypeOf(value) !== plainPrototype && prototypeOf(value) !== null)) {
          throw new fail('Expected a supported Java Map or plain object for request headers');
        }
        var names = keys(value);
        for (var i = 0; i < names.length; i++) {
          var property = descriptorOf(value, names[i]);
          if (!property || !own(property, 'value')) throw new fail('Request headers must not use accessors');
          add(names[i], property.value);
        }
      }
      return stringify(headers);
    }
    function jsoupRawResponse(raw, methodName) {
      arity(arguments, 2, 2, 'raw response');
      jsoupHostObject(raw, 'raw response');
      if (methodName !== 'GET' && methodName !== 'HEAD' && methodName !== 'POST') {
        throw new fail('Unsupported raw HTTP helper method');
      }
      var wireProperty = descriptorOf(raw, 'jsoupResponse');
      if (!wireProperty || !own(wireProperty, 'value') || typeof wireProperty.value !== 'string') {
        throw new fail('Invalid raw HTTP host response: expected jsoupResponse JSON string');
      }
      var wire = jsoupJsonCopy(jsoupHostObject(parse(wireProperty.value), 'raw response JSON'), 0);
      // The raw host wire defaults to GET; the helper is authoritative about the actual method.
      field(wire, 'method', methodName);
      if (methodName === 'HEAD') { field(wire, 'bodyText', ''); field(wire, 'bodyBase64', ''); }
      var request = jsoupRequestState(null);
      request.method = jsoupWireMethod(methodName);
      request.followRedirects = false; request.ignoreContentType = true;
      // Preserve host-visible headers: Foundation-folded fields cannot recover their original first value.
      // Never split ordinary fields on commas; Set-Cookie separation belongs to the host.
      var response = jsoupResponse(wire, request), state = jsoupPrivateData(response, 'response');
      request.url = state.url; request.cookieStore.items = state.cookieStore;
      jsoupCheckResponse(state, request);

      var errorProperty = descriptorOf(raw, 'errorBody');
      if (errorProperty && !own(errorProperty, 'value')) throw new fail('Invalid raw HTTP host errorBody accessor');
      var errorBody = !errorProperty || errorProperty.value === null ? '' :
        jsoupString(errorProperty.value, 'host errorBody', false);
      method(response, 'code', function() { arity(arguments, 0, 0, 'Response.code'); return state.statusCode; });
      method(response, 'message', function() { arity(arguments, 0, 0, 'Response.message'); return state.statusMessage; });
      method(response, 'isSuccessful', function() {
        arity(arguments, 0, 0, 'Response.isSuccessful'); return state.statusCode >= 200 && state.statusCode < 300;
      });
      method(response, 'errorBody', function() { arity(arguments, 0, 0, 'Response.errorBody'); return errorBody; });
      method(response, 'toString', function() {
        arity(arguments, 0, 0, 'Response.toString'); return 'Response{code=' + state.statusCode + ', url=' + state.url + '}';
      });
      return response;
    }
    function jsoupInstallRawHttp(interop) {
      var adapt = interop.rawResponse, headers = interop.rawHeaderJson, variableGet = java.get;
      function execute(methodName, url, body, headerMap) {
        url = jsoupUrl(url);
        if (methodName === 'POST') body = jsoupString(body, 'request body', false);
        var headerJson = headers(headerMap), raw;
        if (methodName === 'POST') {
          if (jsoupRawPost === null) throw new fail('UnsupportedOperationException: __legacyPost host is not available');
          raw = jsoupRawPost(url, body, headerJson);
        } else {
          if (jsoupRawConnect === null) throw new fail('UnsupportedOperationException: __legacyConnectRaw host is not available');
          raw = jsoupRawConnect(methodName === 'HEAD' ? url + ',{"method":"HEAD"}' : url, headerJson);
        }
        return adapt(raw, methodName);
      }
      field(java, 'get', function(url, headerMap) {
        if (arguments.length <= 1) return variableGet(url);
        arity(arguments, 2, 2, 'java.get'); return execute('GET', url, null, headerMap);
      });
      field(java, 'head', function(url, headerMap) {
        arity(arguments, 2, 2, 'java.head'); return execute('HEAD', url, null, headerMap);
      });
      field(java, 'post', function(url, body, headerMap) {
        arity(arguments, 3, 3, 'java.post'); return execute('POST', url, body, headerMap);
      });
    }
""".trimIndent()
