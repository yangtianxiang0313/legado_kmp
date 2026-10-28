package io.legado.kmp.shared.scripting

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive

/** Uses the existing host callbacks, without exposing a second engine or credential storage. */
internal object JsLegacyModelBinding {
    // Native QuickJS host strings may pass through C-string conversion; never start a key with NUL.
    private const val PREFIX = "__legado_ruleData_rpc_v1__:"

    data class Request(val scope: String, val operation: String, val key: String)

    fun request(key: String): Request? {
        if (!key.startsWith(PREFIX)) return null
        val parts = Json.parseToJsonElement(key.removePrefix(PREFIX)) as? JsonArray
            ?: error("Invalid rule variable request")
        require(parts.size == 3) { "Invalid rule variable request" }
        val values = parts.map { (it as? JsonPrimitive)?.takeIf { value -> value.isString }?.content
            ?: error("Invalid rule variable request") }
        return Request(values[0], values[1], values[2])
    }

    fun preamble(hasBook: Boolean, hasChapter: Boolean, hasSource: Boolean): String = """
        (function(read, write, parse, stringify, define, hasOwn) {
          var prefix = ${JsonPrimitive(PREFIX)};
          function request(scope, operation, key) {
            return prefix + stringify([scope, operation, key == null ? '' : String(key)]);
          }
          function get(scope, operation, key) {
            var response = read(request(scope, operation, key));
            if (typeof response !== 'string' || response.length === 0) {
              throw new Error('Rule variable host returned no JSON: ' + scope + '.' + operation);
            }
            return parse(response);
          }
          function put(scope, operation, key, value) {
            write(request(scope, operation, key), value == null ? null : String(value));
            if (scope !== 'source' && typeof java === 'object' && java.__ruleState) {
              if (operation === 'replace') {
                Object.keys(java.__ruleState).forEach(function(name) { delete java.__ruleState[name]; });
              } else { delete java.__ruleState[String(key)]; }
            }
          }
          function bind(target, scope) {
            var methods = Object.create(null);
            function snapshot() { return get(scope, 'map', ''); }
            function set(key, value) { put(scope, 'mapPut', key, value); }
            methods.get = function(key) { var data = snapshot(); return hasOwn.call(data, key) ? data[key] : null; };
            methods.put = function(key, value) { var old = methods.get(key); set(key, value); return old; };
            methods.remove = function(key) { var old = methods.get(key); set(key, null); return old; };
            methods.containsKey = function(key) { return hasOwn.call(snapshot(), key); };
            methods.containsValue = function(value) { return Object.values(snapshot()).indexOf(String(value)) >= 0; };
            methods.size = function() { return Object.keys(snapshot()).length; };
            methods.isEmpty = function() { return methods.size() === 0; };
            methods.keySet = function() { return Object.keys(snapshot()); };
            methods.values = function() { return Object.values(snapshot()); };
            methods.clear = function() { Object.keys(snapshot()).forEach(function(key) { set(key, null); }); };
            methods.putAll = function(values) {
              var data = values && typeof values.toJSON === 'function' ? values.toJSON() : values;
              Object.keys(data || {}).forEach(function(key) { set(key, data[key]); });
            };
            methods.toJSON = snapshot;
            var variableMap = new Proxy(Object.create(null), {
              get: function(_, key) {
                if (typeof key !== 'string') return undefined;
                return hasOwn.call(methods, key) ? methods[key] : snapshot()[key];
              },
              set: function(_, key, value) { if (typeof key !== 'string') return false; set(key, value); return true; },
              deleteProperty: function(_, key) { if (typeof key !== 'string') return false; set(key, null); return true; },
              has: function(_, key) { return hasOwn.call(methods, key) || hasOwn.call(snapshot(), key); },
              ownKeys: function() { return Object.keys(snapshot()); },
              getOwnPropertyDescriptor: function(_, key) {
                var data = snapshot();
                if (hasOwn.call(data, key)) return { configurable: true, enumerable: true, writable: true, value: data[key] };
              }
            });
            function method(name, value) { define(target, name, { value: value, configurable: true, writable: true }); }
            method('getVariable', function(key) {
              return arguments.length === 0 ? get(scope, 'json', '') : get(scope, 'get', key);
            });
            method('putVariable', function(key, value) { put(scope, 'put', key, value); return true; });
            method('getBigVariable', function(key) { return get(scope, 'big', key); });
            method('putBigVariable', function(key, value) { put(scope, 'putBig', key, value); });
            method('getVariableMap', function() { return variableMap; });
            if (scope !== 'source') {
              method('setVariable', function(value) { put(scope, 'replace', '', value); });
              define(target, 'variable', {
                configurable: true, enumerable: true,
                get: function() { return get(scope, 'json', ''); },
                set: function(value) { put(scope, 'replace', '', value); }
              });
              define(target, 'variableMap', { configurable: true, enumerable: true, get: function() { return variableMap; } });
            }
          }
          if ($hasBook) bind(globalThis.book, 'book');
          if ($hasChapter) bind(globalThis.chapter, 'chapter');
          if ($hasSource) bind(globalThis.source, 'source');
        })(__legacyGet, __legacyPut, JSON.parse, JSON.stringify, Object.defineProperty, Object.prototype.hasOwnProperty);
    """.trimIndent() + "\n"
}
