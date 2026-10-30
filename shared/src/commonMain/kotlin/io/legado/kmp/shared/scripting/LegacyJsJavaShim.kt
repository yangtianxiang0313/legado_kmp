package io.legado.kmp.shared.scripting

// Installed inside the DOM closure, before any untrusted jsLib can replace JS natives.
internal val LEGACY_JS_JAVA_SHIM = """
    var javaInterop = (function() {
      var global = globalThis;
      var NativeProxy = Proxy;
      var freeze = Object.freeze;
      var safeInteger = Number.isSafeInteger;
      var finite = Number.isFinite;
      var same = Object.is;
      var descriptorOf = Object.getOwnPropertyDescriptor;
      var NativeUint8Array = Uint8Array;
      var bufferIsView = ArrayBuffer.isView;
      var bufferLength = descriptorOf(ArrayBuffer.prototype, 'byteLength').get;
      var typedArrayPrototype = prototypeOf(NativeUint8Array.prototype);
      var typedArrayKind = descriptorOf(typedArrayPrototype, Symbol.toStringTag).get;
      var typedArrayBuffer = descriptorOf(typedArrayPrototype, 'buffer').get;
      var typedArrayOffset = descriptorOf(typedArrayPrototype, 'byteOffset').get;
      var typedArrayLength = descriptorOf(typedArrayPrototype, 'byteLength').get;
      var floor = Math.floor;
      var trunc = Math.trunc;
      var fround = Math.fround;
      var random = Math.random;
      var now = Date.now;
      var symbolIterator = Symbol.iterator;
      var primitiveKey = Symbol.toPrimitive;
      var invoke = Function.prototype.call.bind(Function.prototype.call);
      var slice = Function.prototype.call.bind(Array.prototype.slice);
      var splice = Function.prototype.call.bind(Array.prototype.splice);
      var sort = Function.prototype.call.bind(Array.prototype.sort);
      var join = Function.prototype.call.bind(Array.prototype.join);
      var stringSlice = Function.prototype.call.bind(String.prototype.slice);
      var charAt = Function.prototype.call.bind(String.prototype.charAt);
      var charCodeAt = Function.prototype.call.bind(String.prototype.charCodeAt);
      var lower = Function.prototype.call.bind(String.prototype.toLowerCase);
      var upper = Function.prototype.call.bind(String.prototype.toUpperCase);
      var trim = Function.prototype.call.bind(String.prototype.trim);
      var fromCharCode = String.fromCharCode;
      var stringIndex = Function.prototype.call.bind(String.prototype.indexOf);
      var stringLastIndex = Function.prototype.call.bind(String.prototype.lastIndexOf);
      var split = Function.prototype.call.bind(String.prototype.split);
      var numberString = Function.prototype.call.bind(Number.prototype.toString);
      var numberExponential = Function.prototype.call.bind(Number.prototype.toExponential);
      var regexTest = Function.prototype.call.bind(RegExp.prototype.test);
      var strToBytes = __legacyStrToBytes;
      var bytesToStr = __legacyBytesToStr;
      var base64DecodeBytes = __legacyBase64DecodeToByteArray;
      var javaHmacBytes = __legacyJavaHmacBytes;
      var states = new WeakMap();
      var stateGet = Function.prototype.call.bind(WeakMap.prototype.get, states);
      var stateSet = Function.prototype.call.bind(WeakMap.prototype.set, states);
      var classes = create(null);
      var classNames = new WeakMap();
      var classNameGet = Function.prototype.call.bind(WeakMap.prototype.get, classNames);
      var classNameSet = Function.prototype.call.bind(WeakMap.prototype.set, classNames);
      var packages = create(null);
      var packageNames = new WeakMap();
      var packageNameGet = Function.prototype.call.bind(WeakMap.prototype.get, packageNames);
      var packageNameSet = Function.prototype.call.bind(WeakMap.prototype.set, packageNames);
      var error = Error;

      function metadata(value) {
        return value !== null && (typeof value === 'object' || typeof value === 'function') ? stateGet(value) : null;
      }
      function method(target, key, value) {
        define(target, key, { value: value, configurable: true, enumerable: false, writable: false });
      }
      function staticClass(members) {
        var target = create(null), names = keys(members);
        for (var i = 0; i < names.length; i++) field(target, names[i], members[names[i]]);
        return freeze(target);
      }
      function unsupported(name) { throw new fail('Unsupported legacy Java namespace or class: ' + name); }
      function arity(args, minimum, maximum, name) {
        if (args.length < minimum || args.length > maximum) throw new fail('Unsupported ' + name + ' overload');
      }
      function index(value, length, end) {
        value = number(unbox(value));
        if (!integer(value) || value < 0 || (end ? value > length : value >= length)) {
          throw new outOfBounds('Java collection index out of bounds: ' + value);
        }
        return value;
      }
      function unbox(value) {
        var data = metadata(value);
        return data && data.kind === 'scalar' ? data.value : value;
      }
      function equal(a, b) {
        if (a === b) return typeof a !== 'number' || same(a, b);
        var left = metadata(a), right = metadata(b);
        if (left && left.kind === 'entry' && right && right.kind === 'entry') {
          return equal(left.key, right.key) && equal(entryValue(left), entryValue(right));
        }
        if (left && left.kind === 'scalar' && right && right.kind === 'scalar' && left.type !== right.type) return false;
        a = unbox(a); b = unbox(b);
        return typeof a === 'number' && typeof b === 'number' ? same(a, b) : a === b;
      }
      function requireValue(value) {
        if (value === undefined) throw new fail('Java collections do not support undefined; use null');
        return value;
      }
      function copyValues(values) {
        var copied = [];
        for (var i = 0; i < values.length; i++) copied[i] = requireValue(values[i]);
        return copied;
      }
      function valuesOf(value) {
        if (isArray(value)) return copyValues(value);
        var data = metadata(value);
        if (data && (data.kind === 'list' || data.kind === 'set')) return slice(data.items);
        if (data && data.kind === 'view') return viewItems(data);
        throw new fail('Expected a supported Java collection or JavaScript array');
      }
      function mapObject(data) {
        var output = create(null);
        for (var i = 0; i < data.items.length; i++) {
          var key = unbox(data.items[i][0]);
          if (key !== null && typeof key !== 'string' && typeof key !== 'number' && typeof key !== 'boolean') {
            throw new fail('Object/symbol Java Map keys cannot cross the JSON bridge');
          }
          var name = string(key);
          if (own(output, name)) throw new fail('Java Map keys collide in JSON: ' + name);
          field(output, name, data.items[i][1]);
        }
        return output;
      }
      function snapshot(value) {
        var data = metadata(value);
        if (!data) return null;
        if (data.kind === 'scalar') return { value: data.value };
        if (data.kind === 'map') return { value: mapObject(data) };
        if (data.kind === 'entry') return { value: { key: data.key, value: entryValue(data) } };
        return { value: valuesOf(value) };
      }
      // Track original wrappers, not freshly allocated snapshots, to reject self-referential collections.
      function jsonSnapshot(value, ancestors) {
        if (value === null || typeof value !== 'object') return value;
        var projected = snapshot(value);
        if (projected && (projected.value === null || typeof projected.value !== 'object')) return projected.value;
        var raw = projected ? projected.value : value;
        var array = isArray(raw);
        if (!array && !projected && prototypeOf(raw) !== plainPrototype && prototypeOf(raw) !== null) return raw;
        for (var ai = 0; ai < ancestors.length; ai++) {
          if (ancestors[ai] === value) throw new fail('Cyclic Java collection JSON value');
        }
        ancestors[ancestors.length] = value;
        var output = array ? [] : create(null);
        var names = array ? null : keys(raw);
        var count = array ? raw.length : names.length;
        for (var i = 0; i < count; i++) {
          var key = array ? i : names[i];
          field(output, key, jsonSnapshot(raw[key], ancestors));
        }
        ancestors.length -= 1;
        return output;
      }
      function registerClass(name, value) {
        classes[name] = value;
        classNameSet(value, name);
      }

      $LEGACY_JS_JAVA_COLLECTIONS
      $LEGACY_JS_JAVA_COLLECTION_ALGORITHMS
      $LEGACY_JS_JAVA_VALUES
      $LEGACY_JS_JAVA_CRYPTO
      $LEGACY_JS_JAVA_CIPHER
      $LEGACY_JS_JAVA_URL
      $LEGACY_JS_JAVA_JSOUP
      $LEGACY_JS_JAVA_RAW_RESPONSE

      registerClass('org.jsoup.Jsoup', org.jsoup.Jsoup);
      registerClass('org.jsoup.Connection', JJsoupConnection);
      registerClass('java.util.ArrayList', JArrayList);
      registerClass('java.util.LinkedList', JLinkedList);
      registerClass('java.util.HashMap', JHashMap);
      registerClass('java.util.LinkedHashMap', JLinkedHashMap);
      registerClass('java.util.HashSet', JHashSet);
      registerClass('java.util.LinkedHashSet', JLinkedHashSet);
      registerClass('java.util.Collections', JCollections);
      registerClass('java.util.Arrays', JArrays);
      registerClass('java.lang.String', JString);
      registerClass('java.lang.Integer', JInteger);
      registerClass('java.lang.Long', JLong);
      registerClass('java.lang.Double', JDouble);
      registerClass('java.lang.Boolean', JBoolean);
      registerClass('java.lang.System', staticClass({ currentTimeMillis: function() { return now(); } }));
      registerClass('android.text.TextUtils', JTextUtils);
      registerClass('java.util.Base64', JBase64);
      registerClass('android.util.Base64', JAndroidBase64);
      registerClass('javax.crypto.Mac', JMac);
      registerClass('javax.crypto.Cipher', JCipher);
      registerClass('javax.crypto.spec.SecretKeySpec', JSecretKeySpec);
      registerClass('javax.crypto.spec.IvParameterSpec', JIvParameterSpec);
      registerClass('javax.xml.bind.DatatypeConverter', JDatatypeConverter);
      registerClass('java.net.URLEncoder', JURLEncoder);
      registerClass('java.net.URLDecoder', JURLDecoder);

      function namespace(name) {
        if (own(packages, name)) return packages[name];
        var children = create(null);
        var prefix = name === '' ? '' : name + '.';
        var names = keys(classes);
        for (var i = 0; i < names.length; i++) {
          if (stringSlice(names[i], 0, prefix.length) !== prefix) continue;
          var remainder = stringSlice(names[i], prefix.length);
          var dot = stringIndex(remainder, '.');
          var shortName = dot < 0 ? remainder : stringSlice(remainder, 0, dot);
          if (!own(children, shortName)) {
            field(children, shortName, dot < 0 ? classes[names[i]] : namespace(prefix + shortName));
          }
        }
        if (name === '') field(children, 'javax', namespace('javax'));
        freeze(children);
        var wrapped = new NativeProxy(children, {
          get: function(target, key) {
            if (typeof key === 'symbol' || key === 'then' || key === 'toJSON') return undefined;
            if (own(target, key)) return target[key];
            unsupported(prefix + string(key));
          }
        });
        packages[name] = wrapped;
        packageNameSet(wrapped, name);
        return wrapped;
      }
      function resolveClass(value) {
        if (typeof value === 'string') {
          if (!own(classes, value)) unsupported(value);
          return { name: value, value: classes[value] };
        }
        var name = value !== null && (typeof value === 'function' || typeof value === 'object') ? classNameGet(value) : null;
        if (!name) throw new fail('Expected a supported Java class, not a package or arbitrary object');
        return { name: name, value: value };
      }
      function aliases(args, allowPackages) {
        var result = create(null);
        function add(name, value) {
          var shortName = stringSlice(name, stringLastIndex(name, '.') + 1);
          if (own(result, shortName) && result[shortName] !== value) throw new fail('Conflicting Java class name: ' + shortName);
          field(result, shortName, value);
        }
        for (var i = 0; i < args.length; i++) {
          var argument = args[i];
          var packageName = argument !== null && typeof argument === 'object' ? packageNameGet(argument) : undefined;
          if (allowPackages && typeof argument === 'string' && own(packages, argument)) packageName = argument;
          if (packageName !== undefined) {
            if (!allowPackages) throw new fail('importClass does not accept Java packages');
            var names = keys(classes), count = 0;
            for (var ci = 0; ci < names.length; ci++) {
              if (stringSlice(names[ci], 0, packageName.length + 1) !== packageName + '.') continue;
              if (stringIndex(stringSlice(names[ci], packageName.length + 1), '.') !== -1) continue;
              add(names[ci], classes[names[ci]]); count++;
            }
            if (!count) throw new fail('Java package has no supported direct classes: ' + packageName);
          } else {
            if (allowPackages === 'packages') throw new fail('importPackage expects a supported leaf Java package');
            var entry = resolveClass(argument);
            add(entry.name, entry.value);
          }
        }
        return result;
      }
      function importAliases(imports) {
        var names = keys(imports);
        for (var i = 0; i < names.length; i++) {
          if (names[i] in global && global[names[i]] !== imports[names[i]]) {
            throw new fail('Cannot import conflicting class name ' + names[i]);
          }
        }
        for (var i = 0; i < names.length; i++) {
          if (!(names[i] in global)) field(global, names[i], imports[names[i]]);
        }
      }
      global.importClass = function() { importAliases(aliases(arguments, false)); };
      global.importPackage = function() { importAliases(aliases(arguments, 'packages')); };
      global.JavaImporter = function() {
        var imports = aliases(arguments, true);
        function append(additions) {
          var names = keys(additions);
          for (var i = 0; i < names.length; i++) {
            if (own(imports, names[i]) && imports[names[i]] !== additions[names[i]]) {
              throw new fail('Conflicting Java class name: ' + names[i]);
            }
          }
          for (var i = 0; i < names.length; i++) {
            if (!own(imports, names[i])) field(imports, names[i], additions[names[i]]);
          }
        }
        method(imports, 'importClass', function() { append(aliases(arguments, false)); });
        method(imports, 'importPackage', function() { append(aliases(arguments, 'packages')); });
        return imports;
      };
      var root = namespace('');
      field(global, 'Packages', root);
      field(global, 'javax', root.javax);
      field(global, 'android', root.android);
      // Keep the original reading host object (ajax/source/crypto/etc.) and add only package children.
      var javaPackages = root.java;
      var javaPackageKeys = keys(javaPackages);
      for (var i = 0; i < javaPackageKeys.length; i++) {
        var name = javaPackageKeys[i];
        if (own(java, name) && java[name] !== javaPackages[name]) throw new fail('Conflicting java host member: ' + name);
        method(java, name, javaPackages[name]);
      }
      var interop = { snapshot: snapshot, rawResponse: jsoupRawResponse, rawHeaderJson: jsoupRawHeaderJson };
      jsoupInstallRawHttp(interop);
      return interop;
    })();
""".trimIndent()
