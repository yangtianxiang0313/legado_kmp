package io.legado.kmp.shared.scripting

internal const val LEGACY_RESPONSE_SUPPORT = """
            function __legacyResponseHeaderValues(headers, allHeaders) {
              var valuesByName = Object.create(null);
              var namesByLowerCase = Object.create(null);
              function add(name, value, fallback) {
                var lowerName = String(name).toLowerCase();
                var storedName = namesByLowerCase[lowerName];
                if (storedName !== undefined) {
                  if (fallback) return;
                } else {
                  storedName = String(name);
                  namesByLowerCase[lowerName] = storedName;
                  valuesByName[storedName] = [];
                }
                var values = Array.isArray(value) ? value : (value == null ? [] : [value]);
                values.forEach(function(item) {
                  if (item != null) valuesByName[storedName].push(String(item));
                });
              }
              allHeaders = __legacyPlainObject(allHeaders || {});
              headers = __legacyPlainObject(headers || {});
              Object.keys(allHeaders).forEach(function(name) { add(name, allHeaders[name], false); });
              Object.keys(headers).forEach(function(name) { add(name, headers[name], true); });
              return valuesByName;
            }
            function __legacyWrapHeaders(headers, allHeaders, useLastValue) {
              var valuesByName = __legacyResponseHeaderValues(headers, allHeaders);
              var headerMap = Object.create(null);
              Object.keys(valuesByName).forEach(function(name) {
                var values = valuesByName[name];
                if (values.length > 0) {
                  headerMap[name] = values[useLastValue ? values.length - 1 : 0];
                }
              });
              function values(name) {
                if (name == null) return [];
                var lowerName = String(name).toLowerCase();
                var names = Object.keys(valuesByName);
                for (var i = 0; i < names.length; i++) {
                  if (names[i].toLowerCase() === lowerName) return valuesByName[names[i]].slice();
                }
                return [];
              }
              var wrapped = {
                raw: headerMap,
                get: function(name) {
                  var matches = values(name);
                  return matches.length > 0 ? matches[useLastValue ? matches.length - 1 : 0] : null;
                },
                values: values,
                toJSON: function() { return headerMap; },
                toString: function() { return JSON.stringify(headerMap); }
              };
              Object.keys(headerMap).forEach(function(name) {
                if (!Object.prototype.hasOwnProperty.call(wrapped, name)) {
                  Object.defineProperty(wrapped, name, { value: headerMap[name], enumerable: true });
                }
              });
              return wrapped;
            }
            function __legacyWrapBodyContent(content) {
              if (content == null) return null;
              return {
                raw: content,
                string: function() { return String(content); },
                toString: function() { return String(content); }
              };
            }
            function __legacyWrapRawResponse(raw, isOkHttp) {
              if (raw == null || typeof raw !== 'object') return raw;
              var responseHeaders = __legacyResponseHeaderValues(raw.headers, raw.allHeaders);
              var wrappedHeaders = __legacyWrapHeaders({}, responseHeaders, isOkHttp);
              var wrapped = {
                url: function() { return raw.url; },
                code: function() { return raw.code != null ? raw.code : raw.statusCode; },
                statusCode: function() { return raw.code != null ? raw.code : raw.statusCode; },
                message: function() { return raw.message != null ? raw.message : raw.statusText; },
                statusMessage: function() { return raw.message != null ? raw.message : raw.statusText; },
                headers: function(name) {
                  return arguments.length > 0 ? wrappedHeaders.values(name) : wrappedHeaders;
                },
                header: function(name, value) {
                  if (isOkHttp) {
                    var lastValue = wrappedHeaders.get(name);
                    return lastValue != null ? lastValue : (value != null ? String(value) : null);
                  }
                  // Jsoup's two-argument overload replaces a header; it is not a default value.
                  if (arguments.length > 1) {
                    var headerName = String(name);
                    Object.keys(responseHeaders).forEach(function(key) {
                      if (key.toLowerCase() === headerName.toLowerCase()) delete responseHeaders[key];
                    });
                    responseHeaders[headerName] = [value != null ? String(value) : ''];
                    wrappedHeaders = __legacyWrapHeaders({}, responseHeaders, false);
                    return wrapped;
                  }
                  var matches = wrappedHeaders.values(name);
                  return matches.length > 0 ? matches.join(', ') : null;
                },
                isSuccessful: function() {
                  if (raw.isSuccessful != null) return raw.isSuccessful;
                  var code = raw.code != null ? raw.code : raw.statusCode;
                  return code >= 200 && code < 300;
                },
                body: function() { return raw.body != null ? String(raw.body) : ''; },
                errorBody: function() { return raw.errorBody != null ? String(raw.errorBody) : ''; },
                toString: function() {
                  return 'Response{code=' + (raw.code != null ? raw.code : raw.statusCode) + ', url=' + raw.url + '}';
                }
              };
              if (isOkHttp) {
                // Only the final request URL is available in the shared response payload.
                var requestUrl = __legacyHttpRequestUrl(raw.url != null ? String(raw.url) : '');
                wrapped.url = function() { return requestUrl; };
                wrapped.request = function() {
                  return { url: function() { return requestUrl; } };
                };
              }
              return wrapped;
            }
            function __legacyWrapResponse(raw) {
              if (raw == null || typeof raw !== 'object') return raw;
              var wrappedHeaders = __legacyWrapHeaders(raw.headers, raw.allHeaders, true);
              var responseUrl = __legacyHttpRequestUrl(raw.url != null ? String(raw.url) : '');
              return {
                response: raw,
                raw: function() { return __legacyWrapRawResponse(raw, true); },
                url: function() { return responseUrl; },
                body: function() { return raw.body; },
                code: function() { return raw.code != null ? raw.code : raw.statusCode; },
                statusCode: function() { return raw.code != null ? raw.code : raw.statusCode; },
                message: function() { return raw.message != null ? raw.message : raw.statusText; },
                statusMessage: function() { return raw.message != null ? raw.message : raw.statusText; },
                headers: function() { return wrappedHeaders; },
                // Retained shim extension; Android StrResponse only declares headers().
                header: function(name) { return wrappedHeaders.get(name); },
                errorBody: function() { return raw.errorBody; },
                isSuccessful: function() {
                  if (raw.isSuccessful != null) return raw.isSuccessful;
                  var code = raw.code != null ? raw.code : raw.statusCode;
                  return code >= 200 && code < 300;
                }
              };
            }
"""
