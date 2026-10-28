package io.legado.kmp.shared.scripting

internal val LEGACY_JS_NATIVE_JSON_SHIM = """
    (function() {
      var registry = new WeakMap();
      var own = Function.prototype.call.bind(Object.prototype.hasOwnProperty);
      var lookup = Function.prototype.call.bind(WeakMap.prototype.get, registry);
      var register = Function.prototype.call.bind(WeakMap.prototype.set, registry);
      var invoke = Function.prototype.call.bind(Function.prototype.call);
      var isArray = Array.isArray;
      var integer = Number.isInteger;
      var names = Object.keys;
      var define = Object.defineProperty;
      var create = Object.create;
      var same = Object.is;
      var prototypeOf = Object.getPrototypeOf;
      var plainPrototype = Object.prototype;
      var primitiveKey = Symbol.toPrimitive;
      var string = String;
      var stringify = JSON.stringify;
      var fail = TypeError;

      function primitive(value) {
        return value === null || (typeof value !== 'object' && typeof value !== 'function');
      }
      // Match OrdinaryToPrimitive(number), including errors from real data fields.
      function numberPrimitive(value, original) {
        if (original !== undefined && original !== null) {
          if (typeof original !== 'function') throw new fail('Cannot convert object to primitive value');
          var converted = invoke(original, value, 'number');
          if (primitive(converted)) return converted;
          throw new fail('Cannot convert object to primitive value');
        }
        var method = value.valueOf;
        if (typeof method === 'function') {
          var converted = invoke(method, value);
          if (primitive(converted)) return converted;
        }
        method = value.toString;
        if (typeof method === 'function') {
          var converted = invoke(method, value);
          if (primitive(converted)) return converted;
        }
        throw new fail('Cannot convert object to primitive value');
      }
      // Same Escape4Web rules as JsonPathValueStrings, also for strings changed by the rule.
      function quote(value) {
        var text = '"';
        for (var i = 0; i < value.length; i++) {
          var code = value.charCodeAt(i);
          if (code === 34) text += '\\"';
          else if (code === 92) text += '\\\\';
          else if (code === 47) text += '\\/';
          else if (code === 8) text += '\\b';
          else if (code === 12) text += '\\f';
          else if (code === 10) text += '\\n';
          else if (code === 13) text += '\\r';
          else if (code === 9) text += '\\t';
          else if (code <= 31 || (code >= 127 && code <= 159) || (code >= 8192 && code <= 8447)) {
            text += '\\u' + ('0000' + code.toString(16).toUpperCase()).slice(-4);
          } else text += value.charAt(i);
        }
        return text + '"';
      }
      function orderedKeys(value, metadata) {
        var ordered = metadata.keys.slice();
        var current = names(value);
        for (var ci = 0; ci < current.length; ci++) {
          if (ordered.indexOf(current[ci]) === -1) ordered[ordered.length] = current[ci];
        }
        return ordered;
      }
      function scalarText(value, metadata, key, json) {
        var original = own(metadata.scalars, key) ? metadata.scalars[key] : null;
        if (original && same(value, original.value)) return json ? original.json : original.java;
        if (!json) return format(value, []);
        return jsonText(value, []);
      }
      function childText(value, metadata, key, ancestors, json) {
        if (primitive(value)) return scalarText(value, metadata, key, json);
        return json ? jsonText(value, ancestors) : format(value, ancestors);
      }
      function jsonText(value, ancestors) {
        if (value === null) return 'null';
        if (typeof value === 'string') return quote(value);
        if (typeof value === 'number') {
          return value === Infinity || value === -Infinity ? 'null' : string(value);
        }
        if (typeof value === 'boolean') return string(value);
        var metadata = typeof value === 'object' ? lookup(value) : null;
        if (metadata) return containerText(value, metadata, ancestors, true);
        // A newly assigned JS value stays a JS value; serialization does not register it.
        var text = stringify(value);
        return text === undefined ? 'null' : text;
      }
      function containerText(value, metadata, ancestors, json) {
        for (var ai = 0; ai < ancestors.length; ai++) {
          if (ancestors[ai] === value) throw new fail('Cyclic native JSON input');
        }
        ancestors[ancestors.length] = value;
        var parts = [];
        if (metadata.kind === 'jsonArray') {
          for (var li = 0; li < value.length; li++) {
            parts[parts.length] = childText(value[li], metadata, li, ancestors, true);
          }
        } else {
          // Do not replace or reorder the object's own string properties.
          var ordered = orderedKeys(value, metadata);
          for (var ki = 0; ki < ordered.length; ki++) {
            var key = ordered[ki];
            if (own(value, key)) {
              parts[parts.length] = (json ? quote(key) + ':' : key + '=') +
                childText(value[key], metadata, key, ancestors, json);
            }
          }
        }
        ancestors.length -= 1;
        if (metadata.kind === 'jsonArray') return '[' + parts.join(',') + ']';
        return '{' + parts.join(json ? ',' : ', ') + '}';
      }
      function format(value, ancestors) {
        var metadata = value !== null && typeof value === 'object' ? lookup(value) : null;
        if (!metadata) return string(value);
        return containerText(value, metadata, ancestors, metadata.kind === 'jsonArray');
      }
      function mark(value, descriptor) {
        if (value === null || typeof value !== 'object' || lookup(value)) return;
        if (descriptor.kind === 'jsonArray' ? !isArray(value) : isArray(value)) return;
        var ordered = [];
        if (descriptor.kind === 'map') {
          var prototype = prototypeOf(value);
          if ((prototype !== plainPrototype && prototype !== null) || !isArray(descriptor.keys)) return;
          for (var i = 0; i < descriptor.keys.length; i++) {
            var key = descriptor.keys[i];
            if (typeof key !== 'string') return;
            if (ordered.indexOf(key) === -1) ordered[ordered.length] = key;
          }
        }
        var scalars = create(null);
        if (isArray(descriptor.scalars)) {
          for (var i = 0; i < descriptor.scalars.length; i++) {
            var scalar = descriptor.scalars[i];
            if (scalar && own(scalar, 'key') && own(scalar, 'value') &&
                typeof scalar.java === 'string' && typeof scalar.json === 'string') {
              scalars[scalar.key] = scalar;
            }
          }
        }
        var original = value[primitiveKey];
        define(value, primitiveKey, {
          enumerable: false,
          configurable: true,
          writable: true,
          value: function(hint) {
            if (hint === 'string' || hint === 'default') {
              if (!lookup(this)) throw new fail('Invalid native JSON receiver');
              return format(this, []);
            }
            return numberPrimitive(this, original);
          }
        });
        register(value, { kind: descriptor.kind, keys: ordered, scalars: scalars });
      }

      // Only bridge-supplied paths establish provenance; [] designates result itself.
      var descriptors = typeof __legacyJsonInputDescriptors !== 'undefined' ? __legacyJsonInputDescriptors : null;
      if (typeof result === 'undefined' || !isArray(descriptors)) return;
      for (var di = 0; di < descriptors.length; di++) {
        var descriptor = descriptors[di];
        if (!descriptor || !own(descriptor, 'path') || !own(descriptor, 'kind') ||
            !isArray(descriptor.path) || (descriptor.kind !== 'map' && descriptor.kind !== 'jsonArray') ||
            (descriptor.kind === 'map' && !own(descriptor, 'keys'))) continue;
        var value = result;
        var path = descriptor.path;
        var resolved = true;
        for (var pi = 0; pi < path.length; pi++) {
          var key = path[pi];
          if (!own(path, pi) ||
              (typeof key !== 'string' && !(typeof key === 'number' && integer(key) && key >= 0)) ||
              value === null || typeof value !== 'object' || !own(value, key)) {
            resolved = false;
            break;
          }
          value = value[key];
        }
        if (resolved) mark(value, descriptor);
      }
      // The existing response adapter also sees result. Explicit native JSON is data,
      // even when it has body/code fields; never send it through response/DOM wrappers.
      var wrapResponse = __legacyWrapResponse;
      __legacyWrapResponse = function(raw) {
        return raw !== null && typeof raw === 'object' && lookup(raw) ? raw : wrapResponse(raw);
      };
    })();
""".trimIndent()
