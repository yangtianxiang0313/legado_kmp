package io.legado.kmp.shared.scripting

internal val LEGACY_JS_JAVA_COLLECTIONS = """
    function find(items, value, entries) {
      for (var i = 0; i < items.length; i++) if (equal(entries ? items[i][0] : items[i], value)) return i;
      return -1;
    }
    function mutable(data, structural) {
      var owner = data.kind === 'view' ? data.owner : data;
      if (owner.readOnly || (structural && owner.fixed)) throw new fail('UnsupportedOperationException: read-only/fixed Java collection');
    }
    function changed(data) { data.version++; }
    function removeAt(data, at) {
      mutable(data, true);
      var removed = splice(data.items, at, 1)[0];
      changed(data);
      return removed;
    }
    function entryValue(data) {
      var at = find(data.owner.items, data.key, true);
      if (at < 0) throw new fail('Java Map entry is no longer present');
      return data.owner.items[at][1];
    }
    function mapEntry(owner, key) {
      var target = create(null);
      var data = { kind: 'entry', owner: owner, key: key };
      stateSet(target, data);
      method(target, 'getKey', function() { return key; });
      method(target, 'getValue', function() { return entryValue(data); });
      method(target, 'setValue', function(value) {
        mutable(owner, false); requireValue(value);
        var at = find(owner.items, key, true);
        if (at < 0) throw new fail('Java Map entry is no longer present');
        var previous = owner.items[at][1]; owner.items[at][1] = value;
        return previous;
      });
      method(target, 'equals', function(other) {
        var entry = metadata(other);
        return !!entry && entry.kind === 'entry' && equal(key, entry.key) && equal(entryValue(data), entryValue(entry));
      });
      method(target, 'toJSON', function() { return jsonSnapshot(target, []); });
      method(target, 'toString', function() { return display(key, [target]) + '=' + display(entryValue(data), [target]); });
      return target;
    }
    function viewItems(data) {
      var output = [];
      for (var i = 0; i < data.owner.items.length; i++) {
        var pair = data.owner.items[i];
        output[i] = data.view === 'keys' ? pair[0] : data.view === 'values' ? pair[1] : mapEntry(data.owner, pair[0]);
      }
      return output;
    }
    function containsItem(data, value) {
      if (data.kind !== 'view') return find(data.items, value, false) >= 0;
      if (data.view === 'keys') return find(data.owner.items, value, true) >= 0;
      for (var i = 0; i < data.owner.items.length; i++) {
        var pair = data.owner.items[i];
        if (data.view === 'values' && equal(pair[1], value)) return true;
        var entry = metadata(value);
        if (data.view === 'entries' && entry && entry.kind === 'entry' && equal(pair[0], entry.key) && equal(pair[1], entryValue(entry))) return true;
      }
      return false;
    }
    function collectionSize(data) { return data.kind === 'view' ? data.owner.items.length : data.items.length; }
    function collectionItems(data) { return data.kind === 'view' ? viewItems(data) : slice(data.items); }
    function removeValue(data, value) {
      mutable(data, true);
      if (data.kind !== 'view') {
        var at = find(data.items, value, false);
        if (at < 0) return false;
        removeAt(data, at); return true;
      }
      for (var i = 0; i < data.owner.items.length; i++) {
        var pair = data.owner.items[i];
        var entry = metadata(value);
        var match = data.view === 'keys' ? equal(pair[0], value) : data.view === 'values' ? equal(pair[1], value) :
          !!entry && entry.kind === 'entry' && equal(pair[0], entry.key) && equal(pair[1], entryValue(entry));
        if (match) { removeAt(data.owner, i); return true; }
      }
      return false;
    }
    function iterator(data) {
      var owner = data.kind === 'view' ? data.owner : data;
      var expected = owner.version, cursor = 0, previous = -1;
      var target = create(null);
      function check() {
        if (expected !== owner.version) throw new error('ConcurrentModificationException: Java collection changed during iteration');
      }
      method(target, 'hasNext', function() { check(); return cursor < collectionSize(data); });
      method(target, 'next', function() {
        check();
        if (cursor >= collectionSize(data)) throw new outOfBounds('NoSuchElementException: Java iterator exhausted');
        previous = cursor++;
        if (data.kind !== 'view') return owner.items[previous];
        var pair = owner.items[previous];
        return data.view === 'keys' ? pair[0] : data.view === 'values' ? pair[1] : mapEntry(owner, pair[0]);
      });
      method(target, 'remove', function() {
        check();
        if (previous < 0) throw new fail('IllegalStateException: call iterator.next before remove');
        removeAt(owner, previous); cursor = previous; previous = -1; expected = owner.version;
      });
      method(target, symbolIterator, function() {
        var adapter = { next: function() {
          return target.hasNext() ? { value: target.next(), done: false } : { value: undefined, done: true };
        } };
        method(adapter, symbolIterator, function() { return adapter; });
        return adapter;
      });
      return target;
    }
    function display(value, ancestors) {
      var data = metadata(value);
      if (!data) return string(value);
      if (data.kind === 'scalar') return data.type === 'Double' ? doubleText(data.value) : string(data.value);
      for (var i = 0; i < ancestors.length; i++) if (ancestors[i] === value) return '(this Collection)';
      ancestors[ancestors.length] = value;
      var parts = [];
      if (data.kind === 'map') {
        for (var i = 0; i < data.items.length; i++) parts[i] = display(data.items[i][0], ancestors) + '=' + display(data.items[i][1], ancestors);
      } else {
        var items = data.kind === 'entry' ? [data.key, entryValue(data)] : collectionItems(data);
        for (var i = 0; i < items.length; i++) parts[i] = display(items[i], ancestors);
      }
      ancestors.length -= 1;
      return data.kind === 'map' ? '{' + join(parts, ', ') + '}' : '[' + join(parts, ', ') + ']';
    }
    function toArray(data, supplied, hasSupplied) {
      var items = collectionItems(data);
      if (!hasSupplied) return items;
      if (!isArray(supplied)) throw new fail('toArray expects a JavaScript array');
      if (supplied.length < items.length) return items;
      for (var i = 0; i < items.length; i++) supplied[i] = items[i];
      if (supplied.length > items.length) supplied[items.length] = null;
      return supplied;
    }
    function collectionMethods(target, data) {
      method(target, 'size', function() { return collectionSize(data); });
      method(target, 'isEmpty', function() { return collectionSize(data) === 0; });
      method(target, 'contains', function(value) { return containsItem(data, value); });
      method(target, 'containsAll', function(values) {
        var items = valuesOf(values);
        for (var i = 0; i < items.length; i++) if (!containsItem(data, items[i])) return false;
        return true;
      });
      method(target, 'removeAll', function(values) {
        mutable(data, true);
        var candidates = valuesOf(values), items = collectionItems(data), removed = false;
        for (var i = 0; i < items.length; i++) {
          if (find(candidates, items[i], false) >= 0) removed = removeValue(data, items[i]) || removed;
        }
        return removed;
      });
      method(target, 'retainAll', function(values) {
        mutable(data, true);
        var candidates = valuesOf(values), items = collectionItems(data), removed = false;
        for (var i = 0; i < items.length; i++) {
          if (find(candidates, items[i], false) < 0) removed = removeValue(data, items[i]) || removed;
        }
        return removed;
      });
      method(target, 'clear', function() {
        mutable(data, true);
        var owner = data.kind === 'view' ? data.owner : data;
        if (owner.items.length) { owner.items.length = 0; changed(owner); }
      });
      method(target, 'toArray', function(array) { return toArray(data, array, arguments.length !== 0); });
      method(target, 'iterator', function() { return iterator(data); });
      method(target, symbolIterator, function() { var it = iterator(data); return it[symbolIterator](); });
      method(target, 'forEach', function(callback) {
        if (typeof callback !== 'function') throw new fail('forEach requires a JavaScript function');
        var it = iterator(data);
        while (it.hasNext()) callback(it.next());
      });
      method(target, 'toJSON', function() { return jsonSnapshot(target, []); });
      method(target, 'toString', function() { return display(target, []); });
    }
    function numericProperty(key) {
      if (typeof key !== 'string' || key === '') return -1;
      var value = number(key);
      return integer(value) && value >= 0 && string(value) === key ? value : -1;
    }
    function list(initial, ctor, options) {
      var items;
      if (initial === undefined) items = [];
      else if (typeof initial === 'number') { index(initial, 2147483647, true); items = []; }
      else items = valuesOf(initial);
      var data = { kind: 'list', items: items, version: 0, readOnly: false, fixed: false };
      if (options) { data.readOnly = !!options.readOnly; data.fixed = !!options.fixed; }
      var target = create(ctor.prototype);
      collectionMethods(target, data);
      method(target, 'get', function(at) { return data.items[index(at, data.items.length, false)]; });
      method(target, 'set', function(at, value) {
        mutable(data, false); at = index(at, data.items.length, false); requireValue(value);
        var old = data.items[at]; data.items[at] = value; return old;
      });
      method(target, 'add', function(at, value) {
        arity(arguments, 1, 2, 'List.add'); mutable(data, true);
        if (arguments.length === 1) { data.items[data.items.length] = requireValue(at); changed(data); return true; }
        at = index(at, data.items.length, true); requireValue(value);
        splice(data.items, at, 0, value); changed(data);
      });
      method(target, 'addAll', function(at, values) {
        arity(arguments, 1, 2, 'List.addAll'); mutable(data, true);
        if (arguments.length === 1) { values = at; at = data.items.length; }
        at = index(at, data.items.length, true);
        var added = valuesOf(values);
        for (var i = 0; i < added.length; i++) splice(data.items, at + i, 0, added[i]);
        if (added.length) changed(data);
        return added.length > 0;
      });
      method(target, 'remove', function(value) {
        if (ctor === JLinkedList && arguments.length === 0) return removeAt(data, index(0, data.items.length, false));
        arity(arguments, 1, 1, 'List.remove');
        // Native integral numbers select remove(int); boxed Java values select remove(Object).
        if (typeof value === 'number' && integer(value)) return removeAt(data, index(value, data.items.length, false));
        return removeValue(data, value);
      });
      method(target, 'removeAt', function(at) { return removeAt(data, index(at, data.items.length, false)); });
      method(target, 'removeObject', function(value) { return removeValue(data, value); });
      method(target, 'indexOf', function(value) { return find(data.items, value, false); });
      method(target, 'lastIndexOf', function(value) {
        for (var i = data.items.length - 1; i >= 0; i--) if (equal(data.items[i], value)) return i;
        return -1;
      });
      method(target, 'sort', function(comparator) { sortList(target, comparator); });
      if (ctor === JLinkedList) {
        method(target, 'addFirst', function(value) { target.add(0, value); });
        method(target, 'addLast', function(value) { target.add(value); });
        method(target, 'getFirst', function() { return target.get(0); });
        method(target, 'getLast', function() { return target.get(data.items.length - 1); });
        method(target, 'peek', function() { return data.items.length ? data.items[0] : null; });
        method(target, 'peekFirst', target.peek);
        method(target, 'peekLast', function() { return data.items.length ? data.items[data.items.length - 1] : null; });
        method(target, 'poll', function() { return data.items.length ? removeAt(data, 0) : null; });
        method(target, 'pollFirst', target.poll);
        method(target, 'pollLast', function() { return data.items.length ? removeAt(data, data.items.length - 1) : null; });
        method(target, 'removeFirst', function() { return removeAt(data, index(0, data.items.length, false)); });
        method(target, 'removeLast', function() { return removeAt(data, index(data.items.length - 1, data.items.length, false)); });
        method(target, 'offer', function(value) { return target.add(value); });
        method(target, 'offerLast', target.offer);
        method(target, 'offerFirst', function(value) { target.add(0, value); return true; });
        method(target, 'push', function(value) { target.add(0, value); });
        method(target, 'pop', target.removeFirst);
      }
      var proxy = new NativeProxy(target, {
        get: function(object, key) {
          if (own(object, key)) return object[key];
          if (key === 'length') return data.items.length;
          var at = numericProperty(key);
          return at >= 0 && at < data.items.length ? data.items[at] : undefined;
        },
        set: function(object, key, value) {
          var at = numericProperty(key);
          if (at < 0) throw new fail('Use Java List methods to change collection state');
          target.set(at, value); return true;
        },
        ownKeys: function() {
          var names = [];
          for (var i = 0; i < data.items.length; i++) names[i] = string(i);
          return names;
        },
        getOwnPropertyDescriptor: function(object, key) {
          if (own(object, key)) return descriptorOf(object, key);
          var at = numericProperty(key);
          return at >= 0 && at < data.items.length ? { value: data.items[at], configurable: true, enumerable: true, writable: !data.readOnly } : undefined;
        },
        has: function(object, key) {
          var at = numericProperty(key);
          return own(object, key) || key === 'length' || at >= 0 && at < data.items.length;
        },
        deleteProperty: function() { throw new fail('Use Java List.remove to remove entries'); },
        defineProperty: function() { throw new fail('Use Java List methods to change collection state'); },
        setPrototypeOf: function() { return false; },
        preventExtensions: function() { return false; }
      });
      stateSet(target, data); stateSet(proxy, data);
      return proxy;
    }
    function JArrayList(initial) { arity(arguments, 0, 1, 'ArrayList'); return list(initial, JArrayList); }
    function JLinkedList(initial) {
      arity(arguments, 0, 1, 'LinkedList');
      if (typeof initial === 'number') throw new fail('LinkedList has no capacity constructor');
      return list(initial, JLinkedList);
    }
    JArrayList.prototype = create(null); JLinkedList.prototype = create(null);

    function mapPairs(value) {
      var data = metadata(value);
      if (data && data.kind === 'map') {
        var pairs = [];
        for (var i = 0; i < data.items.length; i++) pairs[i] = slice(data.items[i]);
        return pairs;
      }
      if (data) throw new fail('Expected a Java Map, not another Java value');
      if (value === null || typeof value !== 'object' || isArray(value) ||
          (prototypeOf(value) !== plainPrototype && prototypeOf(value) !== null)) {
        throw new fail('Expected a supported Java Map or plain JSON object');
      }
      var names = keys(value), pairs = [];
      for (var i = 0; i < names.length; i++) pairs[i] = [names[i], requireValue(value[names[i]])];
      return pairs;
    }
    function map(initial, ctor) {
      var data = { kind: 'map', items: [], version: 0, readOnly: false };
      var target = create(ctor.prototype);
      method(target, 'size', function() { return data.items.length; });
      method(target, 'isEmpty', function() { return data.items.length === 0; });
      method(target, 'containsKey', function(key) { return find(data.items, key, true) >= 0; });
      method(target, 'containsValue', function(value) {
        for (var i = 0; i < data.items.length; i++) if (equal(data.items[i][1], value)) return true;
        return false;
      });
      method(target, 'get', function(key) { var at = find(data.items, key, true); return at < 0 ? null : data.items[at][1]; });
      method(target, 'getOrDefault', function(key, fallback) { var at = find(data.items, key, true); return at < 0 ? fallback : data.items[at][1]; });
      method(target, 'put', function(key, value) {
        mutable(data, true); requireValue(key); requireValue(value);
        var at = find(data.items, key, true);
        if (at < 0) { data.items[data.items.length] = [key, value]; changed(data); return null; }
        var previous = data.items[at][1]; data.items[at][1] = value; return previous;
      });
      method(target, 'putAll', function(other) {
        mutable(data, true); var pairs = mapPairs(other);
        for (var i = 0; i < pairs.length; i++) target.put(pairs[i][0], pairs[i][1]);
      });
      method(target, 'putIfAbsent', function(key, value) {
        mutable(data, true); requireValue(key); requireValue(value);
        var previous = target.get(key);
        if (previous === null) target.put(key, value);
        return previous;
      });
      method(target, 'remove', function(key, value) {
        arity(arguments, 1, 2, 'Map.remove'); mutable(data, true);
        var at = find(data.items, key, true);
        if (arguments.length === 2) {
          if (at < 0 || !equal(data.items[at][1], value)) return false;
          removeAt(data, at); return true;
        }
        return at < 0 ? null : removeAt(data, at)[1];
      });
      method(target, 'replace', function(key, previous, value) {
        arity(arguments, 2, 3, 'Map.replace'); mutable(data, false);
        var at = find(data.items, key, true);
        if (arguments.length === 3) {
          requireValue(value);
          if (at < 0 || !equal(data.items[at][1], previous)) return false;
          data.items[at][1] = value; return true;
        }
        requireValue(previous);
        if (at < 0) return null;
        var old = data.items[at][1]; data.items[at][1] = previous; return old;
      });
      method(target, 'clear', function() { mutable(data, true); if (data.items.length) { data.items.length = 0; changed(data); } });
      function view(kind) {
        var wrapped = create(null);
        var viewData = { kind: 'view', owner: data, view: kind };
        stateSet(wrapped, viewData); collectionMethods(wrapped, viewData);
        method(wrapped, 'remove', function(value) { return removeValue(viewData, value); });
        method(wrapped, 'add', function() { throw new fail('UnsupportedOperationException: cannot add to Java Map views'); });
        method(wrapped, 'addAll', wrapped.add);
        return wrapped;
      }
      method(target, 'keySet', function() { return view('keys'); });
      method(target, 'values', function() { return view('values'); });
      method(target, 'entrySet', function() { return view('entries'); });
      method(target, 'forEach', function(callback) {
        if (typeof callback !== 'function') throw new fail('Map.forEach requires a JavaScript function');
        var it = iterator({ kind: 'view', owner: data, view: 'entries' });
        while (it.hasNext()) { var pair = it.next(); callback(pair.getKey(), pair.getValue()); }
      });
      method(target, 'toJSON', function() { return jsonSnapshot(target, []); });
      method(target, 'toString', function() { return display(target, []); });
      var proxy = new NativeProxy(target, {
        get: function(object, key) {
          if (own(object, key)) return object[key];
          if (typeof key !== 'string') return undefined;
          var at = find(data.items, key, true); return at < 0 ? undefined : data.items[at][1];
        },
        set: function(object, key, value) {
          if (typeof key !== 'string') return false;
          target.put(key, value); return true;
        },
        has: function(object, key) { return own(object, key) || typeof key === 'string' && find(data.items, key, true) >= 0; },
        deleteProperty: function(object, key) { if (typeof key === 'string') target.remove(key); return true; },
        ownKeys: function() {
          var names = [];
          for (var i = 0; i < data.items.length; i++) if (typeof data.items[i][0] === 'string') names[names.length] = data.items[i][0];
          return names;
        },
        getOwnPropertyDescriptor: function(object, key) {
          if (own(object, key)) return descriptorOf(object, key);
          var at = typeof key === 'string' ? find(data.items, key, true) : -1;
          return at < 0 ? undefined : { value: data.items[at][1], configurable: true, enumerable: true, writable: !data.readOnly };
        },
        defineProperty: function() { throw new fail('Use Java Map.put to change map entries'); },
        setPrototypeOf: function() { return false; },
        preventExtensions: function() { return false; }
      });
      stateSet(target, data); stateSet(proxy, data);
      if (initial !== undefined) {
        if (typeof initial === 'number') index(initial, 2147483647, true);
        else target.putAll(initial);
      }
      return proxy;
    }
    function JHashMap(initial) { arity(arguments, 0, 1, 'HashMap'); return map(initial, JHashMap); }
    function JLinkedHashMap(initial) { arity(arguments, 0, 1, 'LinkedHashMap'); return map(initial, JLinkedHashMap); }
    JHashMap.prototype = create(null); JLinkedHashMap.prototype = create(null);

    function set(initial, ctor) {
      var data = { kind: 'set', items: [], version: 0, readOnly: false };
      var target = create(ctor.prototype);
      stateSet(target, data); collectionMethods(target, data);
      method(target, 'add', function(value) {
        mutable(data, true); requireValue(value);
        if (find(data.items, value, false) >= 0) return false;
        data.items[data.items.length] = value; changed(data); return true;
      });
      method(target, 'addAll', function(values) {
        mutable(data, true); var items = valuesOf(values), added = false;
        for (var i = 0; i < items.length; i++) added = target.add(items[i]) || added;
        return added;
      });
      method(target, 'remove', function(value) { return removeValue(data, value); });
      if (initial !== undefined) {
        if (typeof initial === 'number') index(initial, 2147483647, true);
        else target.addAll(initial);
      }
      return target;
    }
    function JHashSet(initial) { arity(arguments, 0, 1, 'HashSet'); return set(initial, JHashSet); }
    function JLinkedHashSet(initial) { arity(arguments, 0, 1, 'LinkedHashSet'); return set(initial, JLinkedHashSet); }
    JHashSet.prototype = create(null); JLinkedHashSet.prototype = create(null);
""".trimIndent()
