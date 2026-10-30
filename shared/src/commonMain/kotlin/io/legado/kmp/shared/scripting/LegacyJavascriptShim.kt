package io.legado.kmp.shared.scripting

internal val LEGACY_SHIM = """
            if (typeof String.prototype.string !== 'function') {
              String.prototype.string = function() { return String(this); };
            }
            if (typeof Array.prototype.toArray !== 'function') {
              Object.defineProperty(Array.prototype, 'toArray', {
                value: function() { return Array.from(this); },
                writable: true,
                configurable: true,
                enumerable: false
              });
            }
            function __legacyPlainObject(value) {
              if (value == null || typeof value !== 'object') return {};
              try {
                return JSON.parse(JSON.stringify(value));
              } catch (e) {
                return value;
              }
            }
            $LEGACY_RESPONSE_SUPPORT
            $LEGACY_MAP_SUPPORT
            function __legacyHeaderJson(header) {
              if (header == null) return null;
              return typeof header === 'string' ? header : JSON.stringify(header);
            }
            function __legacyCryptoArg(value) {
              if (value === undefined || value === null) return null;
              return Array.isArray(value) ? JSON.stringify(value) : String(value);
            }
            function __legacyErrorText(error) {
              if (error == null) return '';
              if (error.stack != null && error.stack !== '') return String(error.stack);
              if (error.message != null && error.message !== '') return String(error.message);
              return String(error);
            }
            function __legacyWrapPojoWithGetters(raw) {
              var wrapped = __legacyPlainObject(raw || {});
              Object.keys(wrapped).forEach(function(key) {
                var methodName = 'get' + key.charAt(0).toUpperCase() + key.slice(1);
                if (wrapped[methodName] === undefined) {
                  wrapped[methodName] = function() {
                    if (key === 'variable') {
                      return __legacyMutableMap(
                        typeof wrapped[key] === 'object' && wrapped[key] != null ? wrapped[key] : {}
                      );
                    }
                    return wrapped[key];
                  };
                }
              });
              if (wrapped.getVariableMap === undefined) {
                wrapped.getVariableMap = function() {
                  return __legacyMutableMap(
                    typeof wrapped.variable === 'object' && wrapped.variable != null ? wrapped.variable : {}
                  );
                };
              }
              if (wrapped.getVariable === undefined) {
                wrapped.getVariable = function(key) {
                  var variableMap = wrapped.getVariableMap();
                  return variableMap.get(key);
                };
              }
              return wrapped;
            }
            globalThis.book = __legacyWrapPojoWithGetters(typeof book === 'object' && book != null ? book : null);
            globalThis.chapter = __legacyWrapPojoWithGetters(typeof chapter === 'object' && chapter != null ? chapter : null);
            var java = typeof java === 'object' && java != null ? java : {};
            java.__headerMap = __legacyMutableHeaderMap(typeof headerMap === 'object' && headerMap != null ? headerMap : {});
            $LEGACY_FONT_SHIM
            java.__ruleState = __legacyPlainObject(typeof __legacyRuleSeed === 'object' && __legacyRuleSeed != null ? __legacyRuleSeed : {});
            java.get = function(key) {
              key = String(key);
              if (Object.prototype.hasOwnProperty.call(java.__ruleState, key)) {
                var stateValue = java.__ruleState[key];
                return stateValue == null ? '' : String(stateValue);
              }
              return __legacyGet(key);
            };
            java.put = function(key, value) {
              var name = String(key);
              java.__ruleState[name] = value;
              globalThis[name] = value;
              __legacyPut(name, value);
              return value;
            };
            java.md5Encode = function(value) { return __legacyMd5Encode(String(value)); };
            java.md5Encode16 = function(value) { return __legacyMd5Encode16(String(value)); };
            java.digestHex = function(data, algorithm) {
              return __legacyDigestHex(data != null ? String(data) : '', algorithm != null ? String(algorithm) : '');
            };
            java.digestBase64Str = function(data, algorithm) {
              return __legacyDigestBase64(data != null ? String(data) : '', algorithm != null ? String(algorithm) : '');
            };
            java.HMacHex = function(data, algorithm, key) {
              return __legacyHMacHex(data != null ? String(data) : '', algorithm != null ? String(algorithm) : '', key != null ? String(key) : '');
            };
            java.HMacBase64 = function(data, algorithm, key) {
              return __legacyHMacBase64(data != null ? String(data) : '', algorithm != null ? String(algorithm) : '', key != null ? String(key) : '');
            };
            java.getHeaderMap = function(includeLoginHeader) {
              var raw = __legacySourceGetHeaderMap(includeLoginHeader === true);
              if (raw == null || raw === undefined) {
                raw = java.__headerMap.toJSON();
              }
              return __legacyMutableHeaderMap(raw);
            };
            java.getSource = function() {
              return (typeof source === 'object' && source != null) ? source : null;
            };
            java.connect = function(url, header) {
              var actualUrl = String(url);
              try {
                var raw = __legacyConnect(actualUrl, __legacyHeaderJson(header));
                return __legacyWrapResponse(raw);
              } catch (error) {
                return __legacyWrapResponse({
                  url: actualUrl,
                  body: __legacyErrorText(error),
                  statusCode: 0,
                  code: 0,
                  statusText: '',
                  message: '',
                  headers: {},
                  allHeaders: {},
                  errorBody: __legacyErrorText(error),
                  isSuccessful: false
                });
              }
            };
            java.ajax = function(url) {
              var actualUrl = Array.isArray(url) ? url[0] : url;
              try {
                return String(java.connect(String(actualUrl)).body());
              } catch (error) {
                return __legacyErrorText(error);
              }
            };
            java.ajaxAll = function(urlList) {
              if (!Array.isArray(urlList)) return [];
              var args = urlList.map(function(url) { return String(url); });
              args.push(null);
              var raw = __legacyConnectAll.apply(null, args);
              if (raw == null || raw === '') return [];
              var parsed;
              try {
                parsed = JSON.parse(String(raw));
              } catch (error) {
                return [];
              }
              if (!Array.isArray(parsed)) return [];
              return parsed.map(function(item) { return __legacyWrapResponse(item); });
            };
            java.getResponse = function() {
              var raw = __legacyGetResponse(JSON.stringify(java.__headerMap.toJSON()));
              return __legacyWrapResponse(raw);
            };
            java.getStrResponse = function(jsStr, sourceRegex) {
              var script = jsStr !== undefined && jsStr !== null ? String(jsStr) : '';
              var regex = sourceRegex !== undefined && sourceRegex !== null ? String(sourceRegex) : '';
              return String(__legacyGetStrResponse(
                script !== '' ? script : null,
                regex !== '' ? regex : null,
                JSON.stringify(java.__headerMap.toJSON())
              ));
            };
            java.log = function(msg) { return __legacyLog(msg); };
            java.logType = function(value) {
              var typeName;
              if (value === null || value === undefined) {
                typeName = 'null';
              } else if (Array.isArray(value)) {
                typeName = 'Array';
              } else if (value.constructor && value.constructor.name) {
                typeName = String(value.constructor.name);
              } else {
                typeName = typeof value;
              }
              __legacyLog(typeName);
            };
            java.timeFormat = function(time) {
              return __legacyTimeFormat(time != null ? time : 0);
            };
            java.timeFormatUTC = function(time, format, sh) {
              return __legacyTimeFormatUTC(time != null ? time : 0, format != null ? String(format) : '', sh != null ? sh : 0);
            };
            java.encodeURI = function(str, enc) {
              return __legacyEncodeURI(str != null ? String(str) : '', enc);
            };
            java.androidId = function() {
              return __legacyAndroidId();
            };
            java.getWebViewUA = function() {
              return __legacyGetWebViewUA();
            };
            java.toURL = function(url, baseUrl) {
              return JSON.parse(__legacyToURL(url != null ? String(url) : '', baseUrl != null ? String(baseUrl) : null));
            };
            java.base64Decode = function(str, flagsOrCharset) {
              return __legacyBase64Decode(str != null ? String(str) : '', flagsOrCharset);
            };
            java.base64Encode = function(str, flags) {
              return __legacyBase64Encode(str != null ? String(str) : '', flags);
            };
            java.cacheFile = function(url, saveTime) {
              return __legacyCacheFile(
                url != null ? String(url) : '',
                saveTime != null ? String(saveTime) : '0'
              );
            };
            java.importScript = function(path) {
              return __legacyImportScript(path != null ? String(path) : '');
            };
            java.downloadFile = function(arg1, arg2) {
              if (arguments.length > 1 && arg2 !== undefined && arg2 !== null) {
                return __legacyDownloadFile(arg1 != null ? String(arg1) : '', String(arg2));
              }
              return __legacyDownloadFile(arg1 != null ? String(arg1) : '');
            };
            java.readFile = function(path) {
              return __legacyReadFile(path != null ? String(path) : '');
            };
            java.readTxtFile = function(path, charsetName) {
              return __legacyReadTxtFile(
                path != null ? String(path) : '',
                charsetName !== undefined && charsetName !== null ? String(charsetName) : null
              );
            };
            java.deleteFile = function(path) {
              return __legacyDeleteFile(path != null ? String(path) : '');
            };
            java.getTxtInFolder = function(path) {
              return __legacyGetTxtInFolder(path != null ? String(path) : '');
            };
            java.getZipByteArrayContent = function(url, path) {
              return __legacyGetZipByteArrayContent(
                url != null ? String(url) : '',
                path != null ? String(path) : ''
              );
            };
            java.getZipStringContent = function(url, path, charsetName) {
              return __legacyGetZipStringContent(
                url != null ? String(url) : '',
                path != null ? String(path) : '',
                charsetName !== undefined && charsetName !== null ? String(charsetName) : null
              );
            };
            java.webView = function(html, url, js) {
              return __legacyWebView(html, url, js);
            };
            java.webViewGetSource = function(html, url, js, sourceRegex) {
              return __legacyWebViewGetSource(html, url, js, sourceRegex != null ? String(sourceRegex) : '');
            };
            java.webViewGetOverrideUrl = function(html, url, js, overrideUrlRegex) {
              return __legacyWebViewGetOverrideUrl(html, url, js, overrideUrlRegex != null ? String(overrideUrlRegex) : '');
            };
            java.createSymmetricCrypto = function(transformation, key, iv) {
              var args = [String(transformation), __legacyCryptoArg(key), __legacyCryptoArg(iv)];
              return {
                encryptBase64: function(data) {
                  return __legacySymmetricEncryptBase64(args[0], args[1], args[2], data != null ? String(data) : '');
                },
                encryptHex: function(data) {
                  return __legacySymmetricEncryptHex(args[0], args[1], args[2], data != null ? String(data) : '');
                },
                decryptStr: function(data) {
                  return __legacySymmetricDecryptStr(args[0], args[1], args[2], data != null ? String(data) : '');
                },
                encrypt: function(data) {
                  return JSON.parse(__legacySymmetricEncrypt(
                    args[0],
                    args[1],
                    args[2],
                    Array.isArray(data) ? JSON.stringify(data) : (data != null ? String(data) : '')
                  ));
                },
                decrypt: function(data) {
                  return JSON.parse(__legacySymmetricDecrypt(
                    args[0],
                    args[1],
                    args[2],
                    Array.isArray(data) ? JSON.stringify(data) : (data != null ? String(data) : '')
                  ));
                }
              };
            };
            java.aesDecodeToByteArray = function(str, key, transformation, iv) {
              return java.createSymmetricCrypto(transformation, key, iv).decrypt(str);
            };
            java.aesDecodeToString = function(str, key, transformation, iv) {
              return java.createSymmetricCrypto(transformation, key, iv).decryptStr(str);
            };
            java.aesDecodeArgsBase64Str = function(data, key, mode, padding, iv) {
              return java.createSymmetricCrypto(
                'AES/' + String(mode) + '/' + String(padding),
                java.base64DecodeToByteArray(key),
                java.base64DecodeToByteArray(iv)
              ).decryptStr(data);
            };
            java.aesBase64DecodeToByteArray = function(str, key, transformation, iv) {
              return java.createSymmetricCrypto(transformation, key, iv).decrypt(str);
            };
            java.aesBase64DecodeToString = function(str, key, transformation, iv) {
              return java.createSymmetricCrypto(transformation, key, iv).decryptStr(str);
            };
            java.aesEncodeToByteArray = function(data, key, transformation, iv) {
              return java.createSymmetricCrypto(transformation, key, iv).encrypt(data);
            };
            java.aesEncodeToString = function(data, key, transformation, iv) {
              return java.createSymmetricCrypto(transformation, key, iv).decryptStr(data);
            };
            java.aesEncodeToBase64ByteArray = function(data, key, transformation, iv) {
              return java.strToBytes(java.createSymmetricCrypto(transformation, key, iv).encryptBase64(data));
            };
            java.aesEncodeToBase64String = function(data, key, transformation, iv) {
              return java.createSymmetricCrypto(transformation, key, iv).encryptBase64(data);
            };
            java.aesEncodeArgsBase64Str = function(data, key, mode, padding, iv) {
              return java.createSymmetricCrypto('AES/' + String(mode) + '/' + String(padding), key, iv).encryptBase64(data);
            };
            java.desDecodeToString = function(data, key, transformation, iv) {
              return java.createSymmetricCrypto(transformation, key, iv).decryptStr(data);
            };
            java.desBase64DecodeToString = function(data, key, transformation, iv) {
              return java.createSymmetricCrypto(transformation, key, iv).decryptStr(data);
            };
            java.desEncodeToString = function(data, key, transformation, iv) {
              return java.bytesToStr(java.createSymmetricCrypto(transformation, key, iv).encrypt(data));
            };
            java.desEncodeToBase64String = function(data, key, transformation, iv) {
              return java.createSymmetricCrypto(transformation, key, iv).encryptBase64(data);
            };
            java.tripleDESDecodeStr = function(data, key, mode, padding, iv) {
              return java.createSymmetricCrypto('DESede/' + String(mode) + '/' + String(padding), key, iv).decryptStr(data);
            };
            java.tripleDESDecodeArgsBase64Str = function(data, key, mode, padding, iv) {
              return java.createSymmetricCrypto(
                'DESede/' + String(mode) + '/' + String(padding),
                java.base64DecodeToByteArray(key),
                iv
              ).decryptStr(data);
            };
            java.tripleDESEncodeBase64Str = function(data, key, mode, padding, iv) {
              return java.createSymmetricCrypto('DESede/' + String(mode) + '/' + String(padding), key, iv).encryptBase64(data);
            };
            java.tripleDESEncodeArgsBase64Str = function(data, key, mode, padding, iv) {
              return java.createSymmetricCrypto(
                'DESede/' + String(mode) + '/' + String(padding),
                java.base64DecodeToByteArray(key),
                iv
              ).encryptBase64(data);
            };
            java.createAsymmetricCrypto = function() {
              var args = [String(arguments[0]), null, null];
              return {
                setPublicKey: function(key) {
                  args[1] = __legacyCryptoArg(key);
                  return this;
                },
                setPrivateKey: function(key) {
                  args[2] = __legacyCryptoArg(key);
                  return this;
                },
                encrypt: function(data, usePublicKey) {
                  return JSON.parse(__legacyAsymmetricEncrypt(
                    args[0],
                    args[1],
                    args[2],
                    usePublicKey !== undefined ? usePublicKey === true : true,
                    Array.isArray(data) ? JSON.stringify(data) : (data != null ? String(data) : '')
                  ));
                },
                encryptBase64: function(data, usePublicKey) {
                  return __legacyAsymmetricEncryptBase64(
                    args[0],
                    args[1],
                    args[2],
                    usePublicKey !== undefined ? usePublicKey === true : true,
                    Array.isArray(data) ? JSON.stringify(data) : (data != null ? String(data) : '')
                  );
                },
                encryptHex: function(data, usePublicKey) {
                  return __legacyAsymmetricEncryptHex(
                    args[0],
                    args[1],
                    args[2],
                    usePublicKey !== undefined ? usePublicKey === true : true,
                    Array.isArray(data) ? JSON.stringify(data) : (data != null ? String(data) : '')
                  );
                },
                decrypt: function(data, usePublicKey) {
                  return JSON.parse(__legacyAsymmetricDecrypt(
                    args[0],
                    args[1],
                    args[2],
                    usePublicKey !== undefined ? usePublicKey === true : true,
                    Array.isArray(data) ? JSON.stringify(data) : (data != null ? String(data) : '')
                  ));
                },
                decryptStr: function(data, usePublicKey) {
                  return __legacyAsymmetricDecryptStr(
                    args[0],
                    args[1],
                    args[2],
                    usePublicKey !== undefined ? usePublicKey === true : true,
                    Array.isArray(data) ? JSON.stringify(data) : (data != null ? String(data) : '')
                  );
                }
              };
            };
            java.createSign = function() {
              var args = [String(arguments[0]), null, null];
              return {
                setPublicKey: function(key) {
                  args[1] = __legacyCryptoArg(key);
                  return this;
                },
                setPrivateKey: function(key) {
                  args[2] = __legacyCryptoArg(key);
                  return this;
                },
                sign: function(data) {
                  return JSON.parse(__legacySign(
                    args[0],
                    args[1],
                    args[2],
                    Array.isArray(data) ? JSON.stringify(data) : (data != null ? String(data) : '')
                  ));
                },
                signHex: function(data) {
                  return __legacySignHex(
                    args[0],
                    args[1],
                    args[2],
                    Array.isArray(data) ? JSON.stringify(data) : (data != null ? String(data) : '')
                  );
                },
                verify: function(data, signature) {
                  return __legacyVerifySign(
                    args[0],
                    args[1],
                    args[2],
                    Array.isArray(data) ? JSON.stringify(data) : (data != null ? String(data) : ''),
                    Array.isArray(signature) ? JSON.stringify(signature) : (signature != null ? String(signature) : '')
                  );
                }
              };
            };
            java.toast = function(msg) { __legacyToast(msg, false); };
            java.longToast = function(msg) { __legacyToast(msg, true); };
            java.startBrowser = function(url, title) {
              __legacyStartBrowser(String(url), title != null ? String(title) : '');
            };
            java.startBrowserAwait = function(url, title, refetchAfterSuccess) {
              var raw = __legacyStartBrowserAwait(
                String(url),
                title != null ? String(title) : '',
                refetchAfterSuccess !== undefined ? refetchAfterSuccess === true : true
              );
              return __legacyWrapRawResponse(raw);
            };
            java.getVerificationCode = function(imageUrl) {
              return __legacyGetVerificationCode(imageUrl != null ? String(imageUrl) : '');
            };
            java.openUrl = function(url, mimeType) {
              __legacyOpenUrl(url != null ? String(url) : '', mimeType != null ? String(mimeType) : null);
            };
            if (typeof __legacyRssSearchBook === 'function') {
              java.searchBook = function(key) { __legacyRssSearchBook(key != null ? String(key) : ''); };
            }
            if (typeof __legacyRssAddBook === 'function') {
              java.addBook = function(bookUrl) { __legacyRssAddBook(bookUrl != null ? String(bookUrl) : ''); };
            }
            java.getCookie = function(url, key) {
              if (key !== undefined && key !== null) {
                return __legacyCookieGetKey(url != null ? String(url) : '', String(key));
              }
              return __legacyGetCookie(url != null ? String(url) : '');
            };
            java.t2s = function(str) { return __legacyT2s(str != null ? String(str) : ''); };
            java.s2t = function(str) { return __legacyS2t(str != null ? String(str) : ''); };
            java.toNumChapter = function(str) { return __legacyToNumChapter(str != null ? String(str) : ''); };
            java.hexDecodeToString = function(str) { return __legacyHexDecodeToString(str != null ? String(str) : ''); };
            java.hexEncodeToString = function(str) { return __legacyHexEncodeToString(str != null ? String(str) : ''); };
            java.hexDecodeToByteArray = function(hex) {
              return __legacyHexDecodeToByteArray(hex != null ? String(hex) : '');
            };
            java.strToBytes = function(str, charset) {
              return __legacyStrToBytes(str != null ? String(str) : '', charset);
            };
            java.bytesToStr = function(bytes, charset) {
              if (!Array.isArray(bytes)) return '';
              return __legacyBytesToStr(JSON.stringify(bytes), charset);
            };
            java.base64DecodeToByteArray = function(str, flags) {
              return __legacyBase64DecodeToByteArray(str, flags);
            };
            java.htmlFormat = function(str) {
              return __legacyHtmlFormat(str != null ? String(str) : '');
            };
            java.randomUUID = function() {
              return __legacyRandomUUID();
            };
            java.setContent = function(content, base) {
              var nextContent = content != null ? String(content) : '';
              var nextBase = base !== undefined && base !== null ? String(base) : null;
              __legacyRuleSetContent(nextContent, nextBase);
              result = nextContent;
              body = nextContent;
              src = nextContent;
              if (nextBase !== null) {
                baseUrl = nextBase;
              }
              return nextContent;
            };
            java.setBaseUrl = function(url) {
              var nextBase = url != null ? String(url) : null;
              __legacyRuleSetBaseUrl(nextBase);
              baseUrl = nextBase != null ? nextBase : '';
              return nextBase;
            };
            java.reGetBook = function() {
              var updated = __legacyReGetBook();
              if (updated != null && typeof updated === 'object') {
                book = updated;
              }
              return updated;
            };
            java.refreshTocUrl = function() {
              var updated = __legacyRefreshTocUrl();
              if (updated != null && typeof updated === 'object') {
                book = updated;
              }
              return updated;
            };
            java.getString = function(rule) {
              var hostValue = __legacyRuleGetString(String(rule));
              if (hostValue !== null && hostValue !== undefined) {
                return String(hostValue);
              }
              if (typeof result === 'string') {
                try {
                  var parsed = JSON.parse(result);
                  if (parsed != null && typeof parsed === 'object') {
                    var keys = String(rule).split('.');
                    var val_ = parsed;
                    for (var ki = 0; ki < keys.length; ki++) {
                      if (val_ == null) return '';
                      val_ = val_[keys[ki]];
                    }
                    return val_ != null ? String(val_) : '';
                  }
                } catch(e) {}
              }
              return '';
            };
            java.getStringList = function(rule) {
              var hostList = __legacyRuleGetStringList(String(rule));
              if (hostList !== null && hostList !== undefined) {
                try { return JSON.parse(String(hostList)); } catch(e) {}
              }
              var r = java.getString(rule);
              if (r === '') return [];
              try { var arr = JSON.parse(r); if (Array.isArray(arr)) return arr; } catch(e) {}
              return [r];
            };
            if (typeof source === 'object' && source != null) {
              var __legacySourceSnapshot = typeof globalThis.__legacySourceSnapshot === 'object' && globalThis.__legacySourceSnapshot != null
                ? globalThis.__legacySourceSnapshot
                : {};
              Object.defineProperty(source, 'key', { get: function() { return source.getKey(); }, configurable: true });
              Object.defineProperty(source, 'tag', { get: function() { return source.getTag(); }, configurable: true });
              Object.defineProperty(source, 'bookSourceUrl', { get: function() { return source.getBookSourceUrl(); }, configurable: true });
              Object.defineProperty(source, 'bookSourceName', { get: function() { return __legacySourceSnapshot.bookSourceName || ''; }, configurable: true });
              Object.defineProperty(source, 'bookSourceGroup', { get: function() { return __legacySourceSnapshot.bookSourceGroup || ''; }, configurable: true });
              Object.defineProperty(source, 'bookSourceType', { get: function() { return __legacySourceSnapshot.bookSourceType != null ? __legacySourceSnapshot.bookSourceType : 0; }, configurable: true });
              Object.defineProperty(source, 'bookUrlPattern', { get: function() { return __legacySourceSnapshot.bookUrlPattern || ''; }, configurable: true });
              Object.defineProperty(source, 'bookSourceComment', { get: function() { return source.getBookSourceComment(); }, configurable: true });
              Object.defineProperty(source, 'header', { get: function() { return __legacySourceSnapshot.header || ''; }, configurable: true });
              Object.defineProperty(source, 'loginUrl', { get: function() { return __legacySourceSnapshot.loginUrl || ''; }, configurable: true });
              Object.defineProperty(source, 'loginUi', { get: function() { return __legacySourceSnapshot.loginUi || ''; }, configurable: true });
              Object.defineProperty(source, 'loginCheckJs', { get: function() { return __legacySourceSnapshot.loginCheckJs || ''; }, configurable: true });
              Object.defineProperty(source, 'coverDecodeJs', { get: function() { return __legacySourceSnapshot.coverDecodeJs || ''; }, configurable: true });
              Object.defineProperty(source, 'variableComment', { get: function() { return __legacySourceSnapshot.variableComment || ''; }, configurable: true });
              Object.defineProperty(source, 'enabledCookieJar', { get: function() { return __legacySourceSnapshot.enabledCookieJar === true; }, configurable: true });
              Object.defineProperty(source, 'concurrentRate', { get: function() { return __legacySourceSnapshot.concurrentRate || ''; }, configurable: true });
              Object.defineProperty(source, 'enabled', { get: function() { return __legacySourceSnapshot.enabled !== false; }, configurable: true });
              Object.defineProperty(source, 'enabledExplore', { get: function() { return __legacySourceSnapshot.enabledExplore !== false; }, configurable: true });
              Object.defineProperty(source, 'customOrder', { get: function() { return __legacySourceSnapshot.customOrder != null ? __legacySourceSnapshot.customOrder : 0; }, configurable: true });
              Object.defineProperty(source, 'lastUpdateTime', { get: function() { return __legacySourceSnapshot.lastUpdateTime != null ? __legacySourceSnapshot.lastUpdateTime : 0; }, configurable: true });
              Object.defineProperty(source, 'respondTime', { get: function() { return __legacySourceSnapshot.respondTime != null ? __legacySourceSnapshot.respondTime : 0; }, configurable: true });
              Object.defineProperty(source, 'weight', { get: function() { return __legacySourceSnapshot.weight != null ? __legacySourceSnapshot.weight : 0; }, configurable: true });
              Object.defineProperty(source, 'exploreUrl', { get: function() { return __legacySourceSnapshot.exploreUrl || ''; }, configurable: true });
              Object.defineProperty(source, 'exploreScreen', { get: function() { return __legacySourceSnapshot.exploreScreen || ''; }, configurable: true });
              Object.defineProperty(source, 'getHeaderMap', {
                value: function(includeLoginHeader) {
                  return __legacyMutableHeaderMap(__legacySourceGetHeaderMap(includeLoginHeader === true));
                },
                configurable: true
              });
              Object.defineProperty(source, 'getSource', {
                value: function() {
                  return source;
                },
                configurable: true
              });
              Object.defineProperty(source, 'getLoginHeaderMap', {
                value: function() {
                  var raw = __legacySourceGetLoginHeaderMap();
                  return raw == null ? null : __legacyMutableHeaderMap(raw);
                },
                configurable: true
              });
              Object.defineProperty(source, 'getLoginInfoMap', {
                value: function() {
                  var raw = __legacySourceGetLoginInfoMap();
                  return raw == null ? null : __legacyMutableMap(raw);
                },
                configurable: true
              });
              Object.defineProperty(source, 'getVariableMap', {
                value: function() {
                  var raw = __legacySourceGetVariableMap();
                  return raw == null ? null : __legacyMutableMap(raw);
                },
                configurable: true
              });
            }
            var org = typeof org === 'object' && org != null ? org : {};
            org.jsoup = typeof org.jsoup === 'object' && org.jsoup != null ? org.jsoup : {};
            var cookie = typeof cookie === 'object' && cookie != null ? cookie : {};
            cookie.getCookie = function(url) { return __legacyGetCookie(url != null ? String(url) : ''); };
            cookie.setCookie = function(url, value) { __legacySetCookie(url != null ? String(url) : '', value != null ? String(value) : ''); };
            cookie.replaceCookie = function(url, value) { __legacyReplaceCookie(url != null ? String(url) : '', value != null ? String(value) : ''); };
            cookie.removeCookie = function(tag) { return __legacyRemoveCookie(tag != null ? String(tag) : ''); };
            cookie.getKey = function(url, key) { return __legacyCookieGetKey(url != null ? String(url) : '', key != null ? String(key) : ''); };
            var cache = typeof cache === 'object' && cache != null ? cache : {};
            cache.get = function(key) { return __legacyCacheGet(String(key)); };
            cache.put = function(key, value, saveTime) { return __legacyCachePut(String(key), value, saveTime); };
            cache.remove = function(key) { return __legacyCacheRemove(String(key)); };
            cache.delete = function(key) { return __legacyCacheRemove(String(key)); };
            cache.getFile = function(key) { return __legacyCacheFileGet(String(key)); };
            cache.putFile = function(key, value, saveTime) { return __legacyCacheFilePut(String(key), value, saveTime); };
            cache.getFromMemory = function(key) { return __legacyCacheMemoryGet(String(key)); };
            cache.putMemory = function(key, value) { return __legacyCacheMemoryPut(String(key), value); };
            cache.deleteMemory = function(key) { return __legacyCacheMemoryRemove(String(key)); };
            $LEGACY_JS_NATIVE_JSON_SHIM
            $LEGACY_JS_DOM_SHIM
            if (typeof response === 'object' && response != null && (response.body !== undefined || response.statusCode !== undefined || response.code !== undefined)) {
              response = __legacyWrapResponse(response);
            }
        """.trimIndent()
