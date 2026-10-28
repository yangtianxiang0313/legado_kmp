package io.legado.kmp.shared.scripting

internal const val LEGACY_MAP_SUPPORT = """
            function __legacyMutableMap(seed, ignoreCase) {
              var state = Object.create(null);
              seed = __legacyPlainObject(seed || {});
              Object.keys(seed).forEach(function(key) { state[key] = seed[key]; });
              function matchingKey(key) {
                var name = String(key);
                if (Object.prototype.hasOwnProperty.call(state, name)) return name;
                if (ignoreCase) {
                  var lower = name.toLowerCase();
                  var keys = Object.keys(state);
                  for (var i = 0; i < keys.length; i++) {
                    if (keys[i].toLowerCase() === lower) return keys[i];
                  }
                }
                return null;
              }
              function get(key) {
                if (key == null) return null;
                var name = matchingKey(key);
                return name === null ? null : state[name];
              }
              var methods = Object.create(null);
              methods.put = function(key, value) {
                var previous = get(key);
                state[String(key)] = ignoreCase ? String(value) : value;
                return previous;
              };
              methods.get = get;
              methods.putAll = function(map) {
                if (!map) return;
                var raw = __legacyPlainObject(map);
                Object.keys(raw).forEach(function(key) { methods.put(key, raw[key]); });
              };
              methods.remove = function(key) {
                var name = matchingKey(key);
                if (name === null) return null;
                var previous = state[name];
                delete state[name];
                return previous;
              };
              methods.clear = function() { state = Object.create(null); };
              methods.toJSON = function() { return state; };
              methods.toString = function() { return JSON.stringify(state); };
              // Rhino exposes Java Map entries through both get() and property access.
              return new Proxy(methods, {
                get: function(target, key) {
                  if (Object.prototype.hasOwnProperty.call(target, key)) return target[key];
                  if (typeof key !== 'string') return undefined;
                  var name = matchingKey(key);
                  return name === null ? undefined : state[name];
                },
                set: function(target, key, value) {
                  if (typeof key !== 'string') return false;
                  methods.put(key, value);
                  return true;
                },
                has: function(target, key) {
                  return Object.prototype.hasOwnProperty.call(target, key) ||
                    typeof key === 'string' && matchingKey(key) !== null;
                },
                deleteProperty: function(target, key) {
                  if (typeof key === 'string') methods.remove(key);
                  return true;
                },
                ownKeys: function() { return Object.keys(state); },
                getOwnPropertyDescriptor: function(target, key) {
                  if (typeof key !== 'string' || !Object.prototype.hasOwnProperty.call(state, key)) return undefined;
                  return { configurable: true, enumerable: true, writable: true, value: state[key] };
                }
              });
            }
            function __legacyMutableHeaderMap(seed) {
              return __legacyMutableMap(seed, true);
            }
"""
