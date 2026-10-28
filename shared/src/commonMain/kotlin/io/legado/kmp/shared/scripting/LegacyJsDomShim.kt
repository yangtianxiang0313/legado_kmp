package io.legado.kmp.shared.scripting

internal val LEGACY_JS_DOM_SHIM = """
    globalThis.__legacyExportDomValue = (function() {
      var registry = new WeakMap();
      var lookup = Function.prototype.call.bind(WeakMap.prototype.get, registry);
      var register = Function.prototype.call.bind(WeakMap.prototype.set, registry);
      var own = Function.prototype.call.bind(Object.prototype.hasOwnProperty);
      var isArray = Array.isArray;
      var keys = Object.keys;
      var create = Object.create;
      var define = Object.defineProperty;
      var prototypeOf = Object.getPrototypeOf;
      var plainPrototype = Object.prototype;
      var parse = JSON.parse;
      var stringify = JSON.stringify;
      var string = String;
      var number = Number;
      var integer = Number.isInteger;
      var fail = TypeError;
      var outOfBounds = RangeError;
      var parseHtml = __legacyDomParse;
      var selectHtml = __legacyDomSelect;
      var htmlAttribute = __legacyDomAttribute;
      var getElementPayload = __legacyRuleGetElementPayload;
      var getStringList = __legacyRuleGetStringList;
      var setContent = __legacyRuleSetDomContent;

      function envelope(kind, value) {
        var node = create(null);
        node.kind = kind;
        node.value = value;
        return node;
      }
      function field(target, key, value) {
        define(target, key, { value: value, enumerable: true, configurable: true, writable: true });
      }
      function copyRaw(raw) {
        return parse(stringify(raw));
      }
      function element(raw) {
        if (raw == null || typeof raw !== 'object') return raw;
        var existing = lookup(raw);
        if (existing) return raw;
        raw = copyRaw(raw);
        var wrapped = {
          __raw: copyRaw(raw),
          text: function() { return raw.text != null ? string(raw.text) : ''; },
          html: function() { return raw.innerHtml != null ? string(raw.innerHtml) : ''; },
          outerHtml: function() { return raw.outerHtml != null ? string(raw.outerHtml) : ''; },
          baseUri: function() { return raw.baseUri != null ? string(raw.baseUri) : ''; },
          attr: function(name) {
            if (name == null) return '';
            var key = string(name);
            if (key.slice(0, 4) === 'abs:') return htmlAttribute(stringify(raw), key);
            return raw.attrs != null && own(raw.attrs, key) ? string(raw.attrs[key]) : '';
          },
          select: function(selector) {
            return elements(parse(selectHtml(stringify(raw), string(selector))));
          },
          toString: function() { return raw.outerHtml != null ? string(raw.outerHtml) : ''; }
        };
        register(wrapped, { kind: 'element', raw: raw });
        return wrapped;
      }
      function elements(rawList) {
        if (rawList != null && lookup(rawList)) return rawList;
        rawList = isArray(rawList) ? rawList : [];
        var wrapped = [];
        for (var i = 0; i < rawList.length; i++) wrapped[i] = element(rawList[i]);
        wrapped.size = function() { return wrapped.length; };
        wrapped.isEmpty = function() { return wrapped.length === 0; };
        wrapped.get = function(index) {
          index = number(index);
          if (!integer(index) || index < 0 || index >= wrapped.length) {
            throw new outOfBounds('Element index out of bounds: ' + index);
          }
          return wrapped[index];
        };
        wrapped.first = function() { return wrapped.length === 0 ? null : wrapped[0]; };
        wrapped.last = function() { return wrapped.length === 0 ? null : wrapped[wrapped.length - 1]; };
        wrapped.text = function() {
          var text = '';
          for (var i = 0; i < wrapped.length; i++) {
            var itemText = wrapped[i].text();
            if (itemText !== '') text += (text === '' ? '' : ' ') + itemText;
          }
          return text;
        };
        wrapped.html = function() {
          var html = '';
          for (var i = 0; i < wrapped.length; i++) {
            if (html !== '') html += '\n';
            html += wrapped[i].html();
          }
          return html;
        };
        wrapped.attr = function(name) { return wrapped.length > 0 ? wrapped[0].attr(name) : ''; };
        wrapped.select = function(selector) {
          var selected = [];
          for (var i = 0; i < wrapped.length; i++) {
            var nested = wrapped[i].select(selector);
            for (var j = 0; j < nested.length; j++) selected[selected.length] = nested[j];
          }
          return elements(selected);
        };
        wrapped.toArray = function() {
          var array = [];
          for (var i = 0; i < wrapped.length; i++) array[i] = wrapped[i];
          return array;
        };
        wrapped.toString = function() {
          var html = '';
          for (var i = 0; i < wrapped.length; i++) {
            if (html !== '') html += '\n';
            html += wrapped[i].outerHtml();
          }
          return html;
        };
        register(wrapped, { kind: 'elements' });
        return wrapped;
      }
      function emptyElement() {
        return { text: '', innerHtml: '', outerHtml: '', tag: 'span', baseUri: '', attrs: {} };
      }
      function hostElements(raw) {
        if (isArray(raw)) return elements(raw);
        if (raw != null && isArray(raw.elements)) return elements(raw.elements);
        return elements(raw != null ? [raw] : []);
      }
      java.getElement = function(rule) {
        var raw = getElementPayload(string(rule));
        if (raw == null || raw === '') return element(emptyElement());
        try {
          var parsed = parse(string(raw));
          if (isArray(parsed) || (parsed != null && isArray(parsed.elements))) return hostElements(parsed);
          return element(parsed);
        } catch (e) {
          var fallback = string(raw);
          return element({ text: fallback, innerHtml: fallback, outerHtml: fallback, attrs: {} });
        }
      };
      java.getElements = function(rule) {
        var raw = getElementPayload(string(rule));
        if (raw == null || raw === '') {
          var list = getStringList(string(rule));
          if (list != null && list !== '') {
            try {
              var parsedList = parse(string(list));
              if (isArray(parsedList)) {
                var payloads = [];
                for (var i = 0; i < parsedList.length; i++) {
                  var text = parsedList[i] != null ? string(parsedList[i]) : '';
                  payloads[i] = { text: text, innerHtml: text, outerHtml: text, attrs: {} };
                }
                return elements(payloads);
              }
            } catch (e) {}
          }
          return elements([]);
        }
        try { return hostElements(parse(string(raw))); }
        catch (e) {
          var fallback = string(raw);
          return elements([{ text: fallback, innerHtml: fallback, outerHtml: fallback, attrs: {} }]);
        }
      };
      org.jsoup.Jsoup = {
        parse: function(html, baseUri) {
          return element(parse(parseHtml(html != null ? string(html) : '', baseUri != null ? string(baseUri) : '')));
        }
      };
      $LEGACY_JS_JAVA_SHIM

      function wrapInput(value, kind) {
        if (value != null && typeof value === 'object' && lookup(value)) return value;
        if (kind === 'element') return element(value);
        return hostElements(value);
      }
      // Paths are relative to result, with [] designating the root. Never inspect JSON shapes for provenance.
      var descriptors = typeof __legacyDomInputDescriptors !== 'undefined' ? __legacyDomInputDescriptors : null;
      var rootWrapped = false;
      var hasDomInput = false;
      if (typeof result !== 'undefined' && isArray(descriptors)) {
        for (var di = 0; di < descriptors.length; di++) {
          var descriptor = descriptors[di];
          if (!descriptor || !isArray(descriptor.path) ||
              (descriptor.kind !== 'element' && descriptor.kind !== 'elements')) continue;
          var path = descriptor.path;
          if (path.length === 0) {
            result = wrapInput(result, descriptor.kind);
            rootWrapped = true;
            hasDomInput = result != null && lookup(result) != null;
            continue;
          }
          var parent = result;
          for (var pi = 0; pi < path.length; pi++) {
            var key = path[pi];
            if ((typeof key !== 'string' && !(typeof key === 'number' && integer(key) && key >= 0)) ||
                parent == null || typeof parent !== 'object' || !own(parent, key)) {
              break;
            }
            if (pi === path.length - 1) {
              parent[key] = wrapInput(parent[key], descriptor.kind);
              hasDomInput = hasDomInput || (parent[key] != null && lookup(parent[key]) != null);
            } else parent = parent[key];
          }
        }
      }
      if (!rootWrapped && typeof result !== 'undefined' && typeof __legacyHtmlResultKind === 'string' &&
          (__legacyHtmlResultKind === 'element' || __legacyHtmlResultKind === 'elements')) {
        result = wrapInput(result, __legacyHtmlResultKind);
        hasDomInput = hasDomInput || (result != null && lookup(result) != null);
      }
      if (!hasDomInput && typeof result === 'object' && result != null &&
          (result.body !== undefined || result.statusCode !== undefined || result.code !== undefined)) {
        result = __legacyWrapResponse(result);
      }

      function encode(value, ancestors) {
        var identity = value;
        var projected = javaInterop.snapshot(value);
        if (projected) value = projected.value;
        if (value == null || (typeof value !== 'object' && typeof value !== 'function')) {
          return { wire: envelope('value', value), containsDom: false, raw: value };
        }
        var registered = lookup(value);
        if (registered && registered.kind === 'element') {
          return { wire: envelope('element', registered.raw), containsDom: true };
        }
        var array = isArray(value);
        var prototype = array ? null : prototypeOf(value);
        if (!array && (typeof value === 'function' ||
            (prototype !== plainPrototype && prototype !== null))) {
          return { wire: envelope('raw', value), containsDom: false, raw: value };
        }
        for (var ai = 0; ai < ancestors.length; ai++) {
          if (ancestors[ai] === identity) throw new fail('Cyclic JavaScript result');
        }
        ancestors[ancestors.length] = identity;
        var children = [];
        var snapshot = array ? [] : create(null);
        var containsDom = false;
        var collection = registered != null && registered.kind === 'elements';
        if (array) {
          var length = value.length;
          for (var i = 0; i < length; i++) {
            var child = encode(value[i], ancestors);
            children[i] = child.wire;
            snapshot[i] = child.raw;
            containsDom = containsDom || child.containsDom;
            collection = collection && child.wire.kind === 'element';
          }
        } else {
          var names = keys(value);
          for (var i = 0; i < names.length; i++) {
            var name = names[i];
            // Read each enumerable property once, including getters. The bridge sees only the snapshot/envelopes.
            var child = encode(value[name], ancestors);
            children[i] = [name, child.wire];
            field(snapshot, name, child.raw);
            containsDom = containsDom || child.containsDom;
          }
        }
        ancestors.length -= 1;
        if (collection) return { wire: envelope('elements', children), containsDom: true };
        if (containsDom) return { wire: envelope(array ? 'array' : 'object', children), containsDom: true };
        return { wire: envelope('raw', snapshot), containsDom: false, raw: snapshot };
      }
      java.setContent = function(content, base) {
        setContent(encode(content, []).wire, base === undefined || base === null ? null : string(base));
        return java;
      };
      return function(value) { return encode(value, []).wire; };
    })();
""".trimIndent()
