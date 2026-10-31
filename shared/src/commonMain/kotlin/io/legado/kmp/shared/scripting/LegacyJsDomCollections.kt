package io.legado.kmp.shared.scripting

// Installed in the DOM closure after the Java shim, before any source library executes.
internal val LEGACY_JS_DOM_COLLECTIONS = """
    var domArrayList = java.util.ArrayList;
    var domUnmodifiableList = java.util.Collections.unmodifiableList;
    var domEmptyList = java.util.Collections.emptyList;
    var domLinkedHashSet = java.util.LinkedHashSet;
    var domProxy = Proxy;
    var domReflectKeys = Reflect.ownKeys;
    var domPropertyDescriptor = Object.getOwnPropertyDescriptor;
    var domArrayPrototype = Array.prototype;
    var domSymbolIterator = Symbol.iterator;
    var domCallback = Function.prototype.call.bind(Function.prototype.call);
    var domHole = create(null), domUndefined = create(null);

    function domNodesList(descriptors, readOnly, emptyNodes) {
      emptyNodes = emptyNodes === true;
      if (emptyNodes && (!readOnly || descriptors.length !== 0)) throw new fail('Invalid empty DOM node list');
      var items = [];
      for (var i = 0; i < descriptors.length; i++) {
        if (!domDescriptor(descriptors[i])) throw new fail('Invalid DOM host Node list member');
        items[i] = node(descriptors[i]);
      }
      var wrapped = emptyNodes ? domEmptyList() : new domArrayList(items);
      if (readOnly && !emptyNodes) wrapped = domUnmodifiableList(wrapped);
      register(wrapped, { kind: 'domList', readOnly: readOnly, emptyNodes: emptyNodes });
      return wrapped;
    }
    function domListValue(value) { return value === domHole || value === domUndefined ? undefined : value; }
    function domStoredValue(value) { return value === undefined ? domUndefined : value; }
    function domListCheck(data) {
      if (data.parent && data.expected !== data.root.version) {
        throw new domError('ConcurrentModificationException: DOM subList is no longer valid');
      }
    }
    function domListSize(data) { domListCheck(data); return data.parent ? data.count : data.root.size(); }
    function domListIndex(value, size, end) {
      value = number(value);
      if (!integer(value) || value < 0 || (end ? value > size : value >= size)) {
        throw new outOfBounds('DOM List index out of bounds: ' + value);
      }
      return value;
    }
    function domNumericProperty(key) {
      if (typeof key !== 'string' || key === '') return -1;
      var at = number(key);
      return integer(at) && at >= 0 && at < 4294967295 && string(at) === key ? at : -1;
    }
    function domListEdited(data, delta) {
      var root = data.root;
      root.version++;
      for (var view = data; view.parent; view = view.parent) {
        view.count += delta;
        view.expected = root.version;
      }
    }
    function domListRaw(data, at) { return data.root.get(data.offset + at); }
    function domListGet(data, at) {
      at = domListIndex(at, domListSize(data), false);
      return domListValue(domListRaw(data, at));
    }
    function domListItems(data) {
      var size = domListSize(data), items = [];
      for (var i = 0; i < size; i++) items[i] = domListValue(domListRaw(data, i));
      return items;
    }
    function domListValues(value) {
      var projected = isArray(value) ? null : javaInterop.snapshot(value);
      var input = projected ? projected.value : value;
      if (!isArray(input)) throw new fail('Expected a Java collection or JavaScript array');
      var copied = [];
      for (var i = 0; i < input.length; i++) {
        var member = input[i];
        if (member === undefined) throw new fail('Java collections do not support undefined; use null');
        copied[i] = member;
      }
      return copied;
    }
    function domListSet(data, at, value, arrayWrite) {
      at = domListIndex(at, domListSize(data), false);
      if (!arrayWrite && value === undefined) throw new fail('Java collections do not support undefined; use null');
      return domListValue(data.root.set(data.offset + at, domStoredValue(value)));
    }
    function domListAdd(data, at, value, arrayWrite) {
      at = domListIndex(at, domListSize(data), true);
      if (!arrayWrite && value === undefined) throw new fail('Java collections do not support undefined; use null');
      data.root.add(data.offset + at, domStoredValue(value));
      domListEdited(data, 1);
    }
    function domListRemoveAt(data, at) {
      at = domListIndex(at, domListSize(data), false);
      var previous = data.root.removeAt(data.offset + at);
      domListEdited(data, -1);
      return domListValue(previous);
    }
    function domListFind(data, value, last) {
      var size = domListSize(data);
      // The existing Java shim supplies boxed-value equality; Elements retain object identity.
      var candidates = [], positions = [];
      for (var i = 0; i < size; i++) {
        var raw = domListRaw(data, i);
        if (raw === domHole || raw === domUndefined) {
          if (value === undefined && !last) return i;
        } else { positions[candidates.length] = i; candidates[candidates.length] = raw; }
      }
      var list = new domArrayList(candidates);
      var found = last ? list.lastIndexOf(value) : list.indexOf(value);
      var at = found < 0 ? -1 : positions[found];
      if (value === undefined && last) {
        for (var i = size - 1; i >= 0; i--) {
          var raw = domListRaw(data, i);
          if (raw === domHole || raw === domUndefined) return i;
        }
      }
      return at;
    }
    function domListRemoveObject(data, value) {
      var at = domListFind(data, value, false);
      if (at < 0) return false;
      domListRemoveAt(data, at); return true;
    }
    function domListRange(data, from, to) {
      var size = domListSize(data);
      from = domListIndex(from, size, true); to = domListIndex(to, size, true);
      if (from > to) throw new fail('IllegalArgumentException: subList fromIndex exceeds toIndex');
      return { from: from, to: to };
    }
    function domListClear(data) {
      var size = domListSize(data);
      for (var i = size - 1; i >= 0; i--) data.root.removeAt(data.offset + i);
      domListEdited(data, -size);
    }
    function domListResize(data, value) {
      var size = domListSize(data), length = number(value);
      if (!integer(length) || length < 0 || length > 2147483647) throw new outOfBounds('Invalid DOM array length');
      if (length === size) return;
      if (length < size) {
        for (var i = size - 1; i >= length; i--) data.root.removeAt(data.offset + i);
      } else {
        for (var i = size; i < length; i++) data.root.add(data.offset + i, domHole);
      }
      domListEdited(data, length - size);
    }
    function domListIterator(data) {
      domListCheck(data);
      var expected = data.root.version, cursor = 0, previous = false;
      var delegate = data.root.iterator();
      for (var i = 0; i < data.offset; i++) delegate.next();
      var next = delegate.next, hasNext = delegate.hasNext, remove = delegate.remove;
      var target = create(null);
      function check() {
        domListCheck(data);
        if (expected !== data.root.version) throw new domError('ConcurrentModificationException: DOM List changed during iteration');
      }
      domMethod(target, 'hasNext', function() { check(); hasNext(); return cursor < domListSize(data); });
      domMethod(target, 'next', function() {
        check();
        if (cursor >= domListSize(data)) throw new outOfBounds('NoSuchElementException: DOM iterator exhausted');
        var value = next(); cursor++; previous = true;
        return domListValue(value);
      });
      domMethod(target, 'remove', function() {
        check();
        if (!previous) throw new fail('IllegalStateException: call iterator.next before remove');
        remove(); domListEdited(data, -1); expected = data.root.version; cursor--; previous = false;
      });
      return target;
    }
    function domListListIterator(data, start) {
      var cursor = domListIndex(start, domListSize(data), true), previous = -1;
      var expected = data.root.version, target = create(null);
      function check() {
        domListCheck(data);
        if (expected !== data.root.version) throw new domError('ConcurrentModificationException: DOM List changed during iteration');
      }
      domMethod(target, 'hasNext', function() { check(); return cursor < domListSize(data); });
      domMethod(target, 'hasPrevious', function() { check(); return cursor > 0; });
      domMethod(target, 'nextIndex', function() { check(); return cursor; });
      domMethod(target, 'previousIndex', function() { check(); return cursor - 1; });
      domMethod(target, 'next', function() {
        check();
        if (cursor >= domListSize(data)) throw new outOfBounds('NoSuchElementException: DOM iterator exhausted');
        previous = cursor++; return domListGet(data, previous);
      });
      domMethod(target, 'previous', function() {
        check();
        if (cursor <= 0) throw new outOfBounds('NoSuchElementException: DOM iterator exhausted');
        previous = --cursor; return domListGet(data, previous);
      });
      domMethod(target, 'remove', function() {
        check();
        if (previous < 0) throw new fail('IllegalStateException: no DOM iterator element to remove');
        domListRemoveAt(data, previous);
        if (previous < cursor) cursor--;
        previous = -1; expected = data.root.version;
      });
      domMethod(target, 'set', function(value) {
        check();
        if (previous < 0) throw new fail('IllegalStateException: no DOM iterator element to set');
        domListSet(data, previous, value, false);
      });
      domMethod(target, 'add', function(value) {
        check(); domListAdd(data, cursor, value, false); cursor++; previous = -1; expected = data.root.version;
      });
      return target;
    }
    function domElementsList(items) {
      var backing = new domArrayList(items);
      var root = { version: 0, size: backing.size, get: backing.get, set: backing.set,
        add: backing.add, removeAt: backing.removeAt, iterator: backing.iterator };
      return domListFacade({ root: root, offset: 0, parent: null }, true);
    }
    function domListFacade(data, isElements) {
      var target = [], wrapped;
      domMethod(target, 'size', function() { return domListSize(data); });
      domMethod(target, 'isEmpty', function() { return domListSize(data) === 0; });
      domMethod(target, 'get', function(at) { return domListGet(data, at); });
      domMethod(target, 'set', function(at, value) { return domListSet(data, at, value, false); });
      domMethod(target, 'add', function(at, value) {
        domArity(arguments, 1, 2, 'List.add');
        if (arguments.length === 1) { domListAdd(data, domListSize(data), at, false); return true; }
        domListAdd(data, at, value, false);
      });
      domMethod(target, 'addAll', function(at, values) {
        domArity(arguments, 1, 2, 'List.addAll');
        if (arguments.length === 1) { values = at; at = domListSize(data); }
        at = domListIndex(at, domListSize(data), true);
        var added = domListValues(values);
        at = domListIndex(at, domListSize(data), true);
        for (var i = 0; i < added.length; i++) data.root.add(data.offset + at + i, added[i]);
        if (added.length) domListEdited(data, added.length);
        return added.length > 0;
      });
      domMethod(target, 'contains', function(value) { return domListFind(data, value, false) >= 0; });
      domMethod(target, 'indexOf', function(value) { return domListFind(data, value, false); });
      domMethod(target, 'lastIndexOf', function(value) { return domListFind(data, value, true); });
      domMethod(target, 'containsAll', function(values) {
        domListCheck(data);
        var items = domListValues(values);
        for (var i = 0; i < items.length; i++) if (domListFind(data, items[i], false) < 0) return false;
        return true;
      });
      domMethod(target, 'remove', function(value) {
        domArity(arguments, isElements ? 0 : 1, 1, 'List.remove');
        if (!arguments.length) {
          var items = domListItems(data);
          for (var i = 0; i < items.length; i++) domCall(items[i], 'remove', []);
          return wrapped;
        }
        if (typeof value === 'number' && integer(value)) return domListRemoveAt(data, value);
        return domListRemoveObject(data, value);
      });
      domMethod(target, 'removeAt', function(at) { return domListRemoveAt(data, at); });
      domMethod(target, 'removeObject', function(value) { return domListRemoveObject(data, value); });
      domMethod(target, 'removeAll', function(values) { return filterList(values, false); });
      domMethod(target, 'retainAll', function(values) { return filterList(values, true); });
      function filterList(values, retain) {
        domListCheck(data);
        var candidates = new domArrayList(domListValues(values)), changed = false;
        for (var i = 0; i < domListSize(data);) {
          if (candidates.contains(domListGet(data, i)) !== retain) { domListRemoveAt(data, i); changed = true; }
          else i++;
        }
        return changed;
      }
      domMethod(target, 'clear', function() { domListClear(data); });
      domMethod(target, 'subList', function(from, to) {
        domArity(arguments, 2, 2, 'List.subList');
        var range = domListRange(data, from, to);
        return domListFacade({ root: data.root, offset: data.offset + range.from, count: range.to - range.from,
          parent: data, expected: data.root.version }, false);
      });
      domMethod(target, 'iterator', function() { return domListIterator(data); });
      domMethod(target, 'listIterator', function(at) {
        domArity(arguments, 0, 1, 'List.listIterator');
        return domListListIterator(data, arguments.length ? at : 0);
      });
      domMethod(target, domSymbolIterator, function() {
        var iterator = domListIterator(data), adapter = create(null);
        domMethod(adapter, 'next', function() {
          return iterator.hasNext() ? { value: iterator.next(), done: false } : { value: undefined, done: true };
        });
        domMethod(adapter, domSymbolIterator, function() { return adapter; });
        return adapter;
      });
      domMethod(target, 'forEach', function(callback, thisArg) {
        if (typeof callback !== 'function') throw new fail('forEach requires a JavaScript function');
        var iterator = domListIterator(data), at = 0;
        while (iterator.hasNext()) domCallback(callback, thisArg, iterator.next(), at++, wrapped);
      });
      domMethod(target, 'toArray', function(array) {
        domArity(arguments, 0, 1, 'List.toArray');
        var items = domListItems(data);
        if (!arguments.length) return items;
        if (!isArray(array)) throw new fail('toArray expects a JavaScript array');
        if (array.length < items.length) return items;
        for (var i = 0; i < items.length; i++) array[i] = items[i];
        if (array.length > items.length) array[items.length] = null;
        return array;
      });
      domMethod(target, 'sort', function(comparator) {
        domArity(arguments, 0, 1, 'List.sort');
        domListCheck(data);
        var expected = data.root.version;
        var values = new domArrayList(domListItems(data));
        values.sort(comparator);
        domListCheck(data);
        if (expected !== data.root.version) throw new domError('ConcurrentModificationException: DOM List changed during sort');
        for (var i = 0; i < values.size(); i++) data.root.set(data.offset + i, values.get(i));
        domListEdited(data, 0);
      });
      if (isElements) domElementsMethods(target, data, function() { return wrapped; });
      else domMethod(target, 'toString', function() { return new domArrayList(domListItems(data)).toString(); });
      wrapped = new domProxy(target, {
        get: function(object, key) {
          domListCheck(data);
          if (key === 'length') return domListSize(data);
          if (own(object, key)) return object[key];
          var at = domNumericProperty(key);
          if (at >= 0) return at < domListSize(data) ? domListGet(data, at) : undefined;
          return domArrayPrototype[key];
        },
        set: function(object, key, value) {
          domListCheck(data);
          if (key === 'length') { domListResize(data, value); return true; }
          var at = domNumericProperty(key);
          if (at >= 0) {
            if (at >= domListSize(data)) domListResize(data, at + 1);
            domListSet(data, at, value, true); return true;
          }
          field(object, key, value); return true;
        },
        ownKeys: function(object) {
          var names = [], size = domListSize(data);
          for (var i = 0; i < size; i++) if (domListRaw(data, i) !== domHole) names[names.length] = string(i);
          var properties = domReflectKeys(object);
          for (var i = 0; i < properties.length; i++) names[names.length] = properties[i];
          return names;
        },
        getOwnPropertyDescriptor: function(object, key) {
          domListCheck(data);
          if (key === 'length') return { value: domListSize(data), configurable: false, enumerable: false, writable: true };
          if (own(object, key)) return domPropertyDescriptor(object, key);
          var at = domNumericProperty(key);
          return at >= 0 && at < domListSize(data) && domListRaw(data, at) !== domHole ?
            { value: domListGet(data, at), configurable: true, enumerable: true, writable: true } : undefined;
        },
        has: function(object, key) {
          domListCheck(data);
          var at = domNumericProperty(key);
          return at >= 0 ? at < domListSize(data) && domListRaw(data, at) !== domHole :
            key === 'length' || own(object, key) || key in domArrayPrototype;
        },
        deleteProperty: function(object, key) {
          domListCheck(data);
          var at = domNumericProperty(key);
          if (at >= 0) {
            if (at < domListSize(data)) data.root.set(data.offset + at, domHole);
            return true;
          }
          return delete object[key];
        },
        defineProperty: function() { throw new fail('Use DOM List methods or array assignment to change collection state'); },
        setPrototypeOf: function() { return false; },
        preventExtensions: function() { return false; }
      });
      register(wrapped, { kind: isElements ? 'elements' : 'domList' });
      return wrapped;
    }
    function domElementsMethods(target, data, self) {
      function all(operation, args) {
        var iterator = domListIterator(data);
        while (iterator.hasNext()) domCall(iterator.next(), operation, args);
        return self();
      }
      function any(operation, args) {
        var iterator = domListIterator(data);
        while (iterator.hasNext()) if (domCall(iterator.next(), operation, args)) return true;
        return false;
      }
      function combined(operation, separator) {
        var result = '', iterator = domListIterator(data);
        while (iterator.hasNext()) {
          if (result !== '') result += separator;
          result += domCall(iterator.next(), operation, []);
        }
        return result;
      }
      function select(operation, arg, hasArg, unique) {
        var output = [], seen = create(null), iterator = domListIterator(data);
        while (iterator.hasNext()) {
          var selected = domCall(iterator.next(), operation, hasArg ? [arg] : []);
          for (var i = 0; i < selected.length; i++) {
            var member = selected[i], state = lookup(member);
            if (!state || state.kind !== 'element') throw new fail('Invalid selected DOM member');
            if (!unique || !own(seen, state.handle)) {
              seen[state.handle] = true; output[output.length] = member;
            }
          }
        }
        return elements(output);
      }
      domMethod(target, 'first', function() {
        domArity(arguments, 0, 0, 'Elements.first'); return domListSize(data) ? domListGet(data, 0) : null;
      });
      domMethod(target, 'last', function() {
        domArity(arguments, 0, 0, 'Elements.last');
        var size = domListSize(data); return size ? domListGet(data, size - 1) : null;
      });
      domMethod(target, 'eq', function(at) {
        domArity(arguments, 1, 1, 'Elements.eq');
        at = number(at);
        if (!integer(at) || at < 0) throw new outOfBounds('DOM Elements index out of bounds: ' + at);
        return elements(at < domListSize(data) ? [domListGet(data, at)] : []);
      });
      domMethod(target, 'text', function() { domArity(arguments, 0, 0, 'Elements.text'); return combined('text', ' '); });
      domMethod(target, 'html', function(value) {
        domArity(arguments, 0, 1, 'Elements.html');
        return arguments.length ? all('html', [domString(value, 'html')]) : combined('html', '\n');
      });
      domMethod(target, 'outerHtml', function() { domArity(arguments, 0, 0, 'Elements.outerHtml'); return combined('outerHtml', '\n'); });
      domMethod(target, 'toString', function() { return combined('outerHtml', '\n'); });
      domMethod(target, 'hasText', function() {
        domArity(arguments, 0, 0, 'Elements.hasText');
        var iterator = domListIterator(data);
        while (iterator.hasNext()) if (domRegexTest(domNonBlankText, domCall(iterator.next(), 'wholeText', []))) return true;
        return false;
      });
      domMethod(target, 'eachText', function() {
        domArity(arguments, 0, 0, 'Elements.eachText');
        var texts = new domArrayList(), add = texts.add, iterator = domListIterator(data);
        while (iterator.hasNext()) {
          var member = iterator.next();
          if (domRegexTest(domNonBlankText, domCall(member, 'wholeText', []))) add(domCall(member, 'text', []));
        }
        return texts;
      });
      domMethod(target, 'attr', function(name, value) {
        domArity(arguments, 1, 2, 'Elements.attr');
        name = domString(name, 'attribute name');
        if (arguments.length === 2) return all('attr', [name, domString(value, 'attribute value')]);
        var iterator = domListIterator(data);
        while (iterator.hasNext()) {
          var member = iterator.next();
          if (domCall(member, 'hasAttr', [name])) return domCall(member, 'attr', [name]);
        }
        return '';
      });
      domMethod(target, 'eachAttr', function(name) {
        domArity(arguments, 1, 1, 'Elements.eachAttr');
        name = domString(name, 'attribute name');
        var attrs = new domArrayList(), add = attrs.add, iterator = domListIterator(data);
        while (iterator.hasNext()) {
          var member = iterator.next();
          if (domCall(member, 'hasAttr', [name])) add(domCall(member, 'attr', [name]));
        }
        return attrs;
      });
      domMethod(target, 'hasAttr', function(name) {
        domArity(arguments, 1, 1, 'Elements.hasAttr'); return any('hasAttr', [domString(name, 'attribute name')]);
      });
      domMethod(target, 'hasClass', function(name) {
        domArity(arguments, 1, 1, 'Elements.hasClass'); return any('hasClass', [domString(name, 'class name')]);
      });
      domMethod(target, 'select', function(query) {
        domArity(arguments, 1, 1, 'Elements.select'); return select('select', domString(query, 'selector'), true, true);
      });
      domMethod(target, 'parents', function() {
        domArity(arguments, 0, 0, 'Elements.parents'); return select('parents', null, false, true);
      });
      domMethod(target, 'clone', function() {
        domArity(arguments, 0, 0, 'Elements.clone');
        var cloned = [], iterator = domListIterator(data);
        while (iterator.hasNext()) cloned[cloned.length] = domCall(iterator.next(), 'clone', []);
        return elements(cloned);
      });
      function unary(name) {
        domMethod(target, name, function(value) {
          domArity(arguments, 1, 1, 'Elements.' + name);
          return all(name, [domString(value, name)]);
        });
      }
      var names = ['tagName', 'removeAttr', 'addClass', 'removeClass', 'toggleClass', 'append', 'prepend', 'before', 'after', 'wrap'];
      for (var i = 0; i < names.length; i++) unary(names[i]);
      domMethod(target, 'empty', function() { domArity(arguments, 0, 0, 'Elements.empty'); return all('empty', []); });
      domMethod(target, 'unwrap', function() { domArity(arguments, 0, 0, 'Elements.unwrap'); return all('unwrap', []); });
    }
""".trimIndent()
