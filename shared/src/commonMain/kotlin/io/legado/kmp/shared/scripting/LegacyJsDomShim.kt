package io.legado.kmp.shared.scripting

internal val LEGACY_JS_DOM_SHIM = """
    globalThis.__legacyExportDomValue = (function() {
      var registry = new WeakMap();
      var lookup = Function.prototype.call.bind(WeakMap.prototype.get, registry);
      var register = Function.prototype.call.bind(WeakMap.prototype.set, registry);
      var adopted = new WeakMap();
      var adoptedGet = Function.prototype.call.bind(WeakMap.prototype.get, adopted);
      var adoptedSet = Function.prototype.call.bind(WeakMap.prototype.set, adopted);
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
      var domError = Error;
      var domRegexTest = Function.prototype.call.bind(RegExp.prototype.test);
      var domNonBlankText = /[^ \t\n\f\r]/;
      var nativeParse = __legacyDomParse;
      var nativeAdopt = __legacyDomAdopt;
      var nativeInvoke = __legacyDomInvoke;
      var nativeCreate = typeof __legacyDomCreate === 'function' ? __legacyDomCreate : null;
      var getElementPayload = __legacyRuleGetElementPayload;
      var getStringList = __legacyRuleGetStringList;
      var setContent = __legacyRuleSetDomContent;
      var byHandle = create(null);

      function envelope(kind, value) {
        var node = create(null);
        node.kind = kind;
        node.value = value;
        return node;
      }
      function field(target, key, value) {
        define(target, key, { value: value, enumerable: true, configurable: true, writable: true });
      }
      function domMethod(target, key, value) {
        define(target, key, { value: value, enumerable: false, configurable: true, writable: true });
      }
      function domArity(args, minimum, maximum, name) {
        if (args.length < minimum || args.length > maximum) throw new fail('Unsupported DOM ' + name + ' overload');
      }
      function domString(value, label) {
        if (value === null || value === undefined) throw new fail('DOM ' + label + ' must not be null');
        return string(value);
      }
      function domDescriptor(raw) {
        return raw !== null && typeof raw === 'object' && !isArray(raw) &&
          own(raw, 'handle') && typeof raw.handle === 'string' && raw.handle !== '' &&
          own(raw, 'document') && typeof raw.document === 'boolean' &&
          (!own(raw, 'nodeType') || (raw.document === false &&
            (raw.nodeType === 'text' || raw.nodeType === 'comment' || raw.nodeType === 'data' || raw.nodeType === 'node')));
      }
      function domReply(raw) {
        if (typeof raw !== 'string') throw new fail('Invalid DOM host JSON response');
        return parse(raw);
      }
      function domCall(target, operation, args) {
        var state = domNodeState(target);
        if (!state) throw new fail('Expected a registered DOM Node');
        var reply = domReply(nativeInvoke(state.handle, operation, stringify(args)));
        if (!reply || typeof reply !== 'object' || !own(reply, 'value')) throw new fail('Invalid DOM host envelope');
        if (reply.kind === 'value') return reply.value;
        if (reply.kind === 'element') {
          if (reply.value === null) return null;
          if (!domElementDescriptor(reply.value)) throw new fail('Invalid DOM host Element descriptor');
          return element(reply.value);
        }
        if (reply.kind === 'elements') {
          if (!isArray(reply.value)) throw new fail('Invalid DOM host Elements descriptor');
          for (var i = 0; i < reply.value.length; i++) {
            if (!domElementDescriptor(reply.value[i])) throw new fail('Invalid DOM host collection member');
          }
          return elements(reply.value);
        }
        if (reply.kind === 'node') return node(reply.value);
        if (reply.kind === 'nodes') {
          if (!isArray(reply.value) || typeof reply.readOnly !== 'boolean') throw new fail('Invalid DOM host Node list descriptor');
          return domNodesList(reply.value, reply.readOnly, reply.emptyNodes === true);
        }
        throw new fail('Unknown DOM host envelope kind');
      }
      $LEGACY_JS_DOM_NODES

      // Only native replies, trusted input descriptors and rule-host results enter this function.
      function element(raw) {
        if (raw == null || typeof raw !== 'object') return raw;
        var existing = lookup(raw);
        if (existing && existing.kind === 'element') return raw;
        if (existing && existing.kind === 'node') throw new fail('Expected a registered DOM Element');
        if (!domDescriptor(raw)) {
          var previous = adoptedGet(raw);
          if (previous) return previous;
          var descriptor = domReply(nativeAdopt(stringify(raw)));
          if (!domElementDescriptor(descriptor)) throw new fail('Invalid adopted DOM descriptor');
          var adoptedElement = element(descriptor);
          adoptedSet(raw, adoptedElement);
          return adoptedElement;
        }
        if (!domElementDescriptor(raw)) throw new fail('Expected a DOM Element descriptor');
        var handle = raw.handle;
        if (own(byHandle, handle)) {
          var cached = byHandle[handle], state = domNodeState(cached);
          if (!state || state.kind !== 'element' || state.document !== raw.document) throw new fail('Conflicting DOM Element descriptor');
          return cached;
        }
        var wrapped = {};
        register(wrapped, { kind: 'element', handle: handle, document: raw.document });
        byHandle[handle] = wrapped;
        // Compatibility/debug data is deliberately not the export authority.
        field(wrapped, '__raw', { handle: handle, document: raw.document });
        domNodeMethods(wrapped);
        function read(name) {
          domMethod(wrapped, name, function() {
            domArity(arguments, 0, 0, name);
            return domCall(wrapped, name, []);
          });
        }
        function readWrite(name) {
          domMethod(wrapped, name, function(value) {
            domArity(arguments, 0, 1, name);
            return domCall(wrapped, name, arguments.length ? [domString(value, name)] : []);
          });
        }
        function unary(name) {
          domMethod(wrapped, name, function(value) {
            domArity(arguments, 1, 1, name);
            return domCall(wrapped, name, [domString(value, name)]);
          });
        }
        var reads = ['parents', 'children', 'siblingElements', 'nextElementSibling',
          'previousElementSibling', 'ownText', 'wholeText', 'data', 'className', 'childrenSize', 'textNodes', 'dataNodes'];
        for (var i = 0; i < reads.length; i++) read(reads[i]);
        var writes = ['text', 'html', 'tagName', 'id'];
        for (var i = 0; i < writes.length; i++) readWrite(writes[i]);
        var unaryNames = ['select', 'selectFirst', 'hasAttr', 'hasClass', 'absUrl', 'getElementsByTag',
          'getElementsByClass', 'getElementById', 'addClass', 'removeClass', 'toggleClass', 'removeAttr',
          'append', 'prepend', 'appendElement', 'prependElement', 'appendText', 'prependText'];
        for (var i = 0; i < unaryNames.length; i++) unary(unaryNames[i]);
        domMethod(wrapped, 'child', function(index) {
          domArity(arguments, 1, 1, 'child');
          return domCall(wrapped, 'child', [domNodeIndex(index, 'child index')]);
        });
        function childNodeMutation(name) {
          domMethod(wrapped, name, function(value) {
            domArity(arguments, 1, 1, name);
            domCall(wrapped, name, [domNodeHandle(value)]);
            return wrapped;
          });
        }
        childNodeMutation('appendChild'); childNodeMutation('prependChild');
        domMethod(wrapped, 'attr', function(name, value) {
          domArity(arguments, 1, 2, 'attr');
          var args = [domString(name, 'attribute name')];
          if (arguments.length === 2) args[1] = typeof value === 'boolean' ? value : domString(value, 'attribute value');
          return domCall(wrapped, 'attr', args);
        });
        domMethod(wrapped, 'classNames', function(values) {
          domArity(arguments, 0, 1, 'classNames');
          if (!arguments.length) return new domLinkedHashSet(domCall(wrapped, 'classNames', []));
          var items = domListValues(values), names = [];
          for (var i = 0; i < items.length; i++) names[i] = domString(items[i], 'class name');
          return domCall(wrapped, 'classNames', [names]);
        });
        domMethod(wrapped, 'hasText', function() {
          domArity(arguments, 0, 0, 'hasText');
          // Jsoup TextNode.isBlank uses the five HTML whitespace characters, not JS \s.
          return domRegexTest(domNonBlankText, domCall(wrapped, 'wholeText', []));
        });
        if (raw.document) {
          read('head'); read('body'); read('location');
          domMethod(wrapped, 'title', function(value) {
            domArity(arguments, 0, 1, 'title');
            if (!arguments.length) return domCall(wrapped, 'title', []);
            domCall(wrapped, 'title', [domString(value, 'title')]);
          });
        }
        return wrapped;
      }
      function elements(rawList) {
        var registered = rawList != null && typeof rawList === 'object' ? lookup(rawList) : null;
        if (registered && registered.kind === 'elements') return rawList;
        rawList = isArray(rawList) ? rawList : [];
        var wrapped = [];
        for (var i = 0; i < rawList.length; i++) wrapped[i] = element(rawList[i]);
        return domElementsList(wrapped);
      }
      function emptyElement() {
        return { text: '', innerHtml: '', outerHtml: '', tag: 'span', baseUri: '', attrs: {} };
      }
      function hostElements(raw) {
        if (isArray(raw)) return elements(raw);
        if (raw != null && typeof raw === 'object') {
          if (isArray(raw.nodes) && typeof raw.readOnly === 'boolean') return domNodesList(raw.nodes, raw.readOnly, raw.emptyNodes === true);
          var members = raw.elements;
          if (isArray(members)) return elements(members);
        }
        return elements(raw != null ? [raw] : []);
      }
      function hostPayload(raw) {
        if (typeof raw !== 'string') return raw;
        try { return parse(raw); }
        catch (e) { return { text: raw, innerHtml: raw, outerHtml: raw, attrs: {} }; }
      }
      java.getElement = function(rule) {
        var raw = getElementPayload(string(rule));
        if (raw == null || raw === '') return element(emptyElement());
        var payload = hostPayload(raw);
        if (domDescriptor(payload)) return node(payload);
        if (isArray(payload) || (payload != null && typeof payload === 'object' &&
            (isArray(payload.elements) || isArray(payload.nodes)))) {
          return hostElements(payload);
        }
        return element(payload);
      };
      java.getElements = function(rule) {
        var raw = getElementPayload(string(rule));
        if (raw != null && raw !== '') return hostElements(hostPayload(raw));
        var list = getStringList(string(rule));
        if (list == null || list === '') return elements([]);
        var parsedList;
        try { parsedList = typeof list === 'string' ? parse(list) : list; }
        catch (e) { return elements([]); }
        if (!isArray(parsedList)) return elements([]);
        var payloads = [];
        for (var i = 0; i < parsedList.length; i++) {
          var text = parsedList[i] != null ? string(parsedList[i]) : '';
          payloads[i] = { text: text, innerHtml: text, outerHtml: text, attrs: {} };
        }
        return elements(payloads);
      };
      org.jsoup.Jsoup = {
        parse: function(html, baseUri) {
          domArity(arguments, 1, 2, 'Jsoup.parse');
          return element(domReply(nativeParse(html != null ? string(html) : '', baseUri != null ? string(baseUri) : '')));
        }
      };

      // The HTTP charset detector still consumes this private legacy shape. Selection
      // resolves the registered handle and reads meta attributes; it never reparses outerHtml.
      function parseHtml(html, baseUri) {
        var document = element(domReply(nativeParse(html, baseUri)));
        var state = lookup(document);
        return stringify({ handle: state.handle, document: state.document, outerHtml: domCall(document, 'outerHtml', []) });
      }
      function selectHtml(payload, selector) {
        var descriptor = parse(payload);
        if (!domDescriptor(descriptor) || !own(byHandle, descriptor.handle)) throw new fail('Unknown DOM charset document');
        var selected = domCall(byHandle[descriptor.handle], 'select', [selector]);
        var metas = [];
        var names = ['http-equiv', 'content', 'charset'];
        for (var i = 0; i < selected.length; i++) {
          var attrs = create(null);
          for (var j = 0; j < names.length; j++) {
            if (domCall(selected[i], 'hasAttr', [names[j]])) field(attrs, names[j], domCall(selected[i], 'attr', [names[j]]));
          }
          metas[i] = { attrs: attrs };
        }
        return stringify(metas);
      }
      $LEGACY_JS_JAVA_SHIM
      $LEGACY_JS_DOM_COLLECTIONS

      function wrapInput(value, kind) {
        if (value != null && typeof value === 'object' && lookup(value)) return value;
        if (kind === 'element') return element(value);
        if (kind === 'node') return node(value);
        if (kind === 'nodes') {
          if (!value || !isArray(value.nodes) || typeof value.readOnly !== 'boolean') throw new fail('Invalid DOM Node list input');
          return domNodesList(value.nodes, value.readOnly, value.emptyNodes === true);
        }
        return hostElements(value);
      }
      // Paths are relative to result. JSON shapes alone never establish DOM provenance.
      var descriptors = typeof __legacyDomInputDescriptors !== 'undefined' ? __legacyDomInputDescriptors : null;
      var rootWrapped = false;
      var hasDomInput = false;
      if (typeof result !== 'undefined' && isArray(descriptors)) {
        for (var di = 0; di < descriptors.length; di++) {
          var descriptor = descriptors[di];
          if (!descriptor || !isArray(descriptor.path) ||
              (descriptor.kind !== 'element' && descriptor.kind !== 'elements' && descriptor.kind !== 'node' && descriptor.kind !== 'nodes')) continue;
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
                parent == null || typeof parent !== 'object' || !own(parent, key)) break;
            if (pi === path.length - 1) {
              var wrappedInput = wrapInput(parent[key], descriptor.kind);
              parent[key] = wrappedInput;
              hasDomInput = hasDomInput || (wrappedInput != null && lookup(wrappedInput) != null);
            } else parent = parent[key];
          }
        }
      }
      if (!rootWrapped && typeof result !== 'undefined' && typeof __legacyHtmlResultKind === 'string' &&
          (__legacyHtmlResultKind === 'element' || __legacyHtmlResultKind === 'elements' || __legacyHtmlResultKind === 'node' || __legacyHtmlResultKind === 'nodes')) {
        result = wrapInput(result, __legacyHtmlResultKind);
        hasDomInput = hasDomInput || (result != null && lookup(result) != null);
      }
      if (!hasDomInput && typeof result === 'object' && result != null &&
          (result.body !== undefined || result.statusCode !== undefined || result.code !== undefined)) {
        result = __legacyWrapResponse(result);
      }

      function encode(value, ancestors) {
        var identity = value;
        var sourceRegistration = value !== null && (typeof value === 'object' || typeof value === 'function') ? lookup(value) : null;
        var projected = javaInterop.snapshot(value);
        if (projected) value = projected.value;
        if (value == null || (typeof value !== 'object' && typeof value !== 'function')) {
          return { wire: envelope('value', value), containsDom: false, raw: value };
        }
        var registered = lookup(value);
        if (registered && (registered.kind === 'element' || registered.kind === 'node')) {
          var reference = create(null);
          reference.handle = registered.handle;
          return { wire: envelope(registered.kind, reference), containsDom: true };
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
            // Evaluate each enumerable getter once, before the bridge sees the snapshot.
            var child = encode(value[name], ancestors);
            children[i] = [name, child.wire];
            field(snapshot, name, child.raw);
            containsDom = containsDom || child.containsDom;
          }
        }
        ancestors.length -= 1;
        if (sourceRegistration && sourceRegistration.kind === 'domList') {
          var listWire = envelope('nodes', children);
          field(listWire, 'readOnly', sourceRegistration.readOnly);
          field(listWire, 'emptyNodes', sourceRegistration.emptyNodes);
          return { wire: listWire, containsDom: true };
        }
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
