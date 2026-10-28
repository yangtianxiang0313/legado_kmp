package io.legado.kmp.shared.scripting

internal val LEGACY_JS_JAVA_COLLECTION_ALGORITHMS = """
    function compareWith(comparator) {
      if (comparator == null) return function(a, b) {
        a = unbox(a); b = unbox(b);
        if (a === null || b === null || typeof a !== typeof b ||
            (typeof a !== 'number' && typeof a !== 'string' && typeof a !== 'boolean')) {
          throw new fail('Natural Java ordering requires non-null comparable scalar values');
        }
        if (typeof a === 'number') {
          if (a !== a) return b !== b ? 0 : 1;
          if (b !== b) return -1;
          if (a === 0 && b === 0 && !same(a, b)) return same(a, -0) ? -1 : 1;
        }
        return a < b ? -1 : a > b ? 1 : 0;
      };
      var compare = typeof comparator === 'function' ? comparator : comparator.compare;
      if (typeof compare !== 'function') throw new fail('Expected a comparator function or {compare(a,b)}');
      return function(a, b) {
        var result = number(unbox(invoke(compare, comparator, a, b)));
        if (!finite(result)) throw new fail('Comparator must return a finite number');
        return result;
      };
    }
    function writableList(value) {
      if (isArray(value)) return { items: value, version: 0 };
      var data = metadata(value);
      if (!data || data.kind !== 'list') throw new fail('Expected a Java List or JavaScript array');
      mutable(data, false); return data;
    }
    function sortList(value, comparator) {
      var data = writableList(value);
      var sorted = slice(data.items);
      sort(sorted, compareWith(comparator));
      for (var i = 0; i < sorted.length; i++) data.items[i] = sorted[i];
      changed(data);
    }
    function searchSorted(items, from, to, value, comparator) {
      var compare = compareWith(comparator), low = from, high = to - 1;
      while (low <= high) {
        var mid = floor((low + high) / 2), result = compare(items[mid], value);
        if (result < 0) low = mid + 1;
        else if (result > 0) high = mid - 1;
        else return mid;
      }
      return -low - 1;
    }
    function immutableList(values) {
      return list(values, JArrayList, { readOnly: true });
    }
    var JCollections = staticClass({
      emptyList: function() { return immutableList([]); },
      singletonList: function(value) { return immutableList([requireValue(value)]); },
      nCopies: function(count, value) {
        count = index(count, 2147483647, true); requireValue(value);
        var items = []; for (var i = 0; i < count; i++) items[i] = value;
        return immutableList(items);
      },
      emptySet: function() { var value = new JHashSet(); metadata(value).readOnly = true; return value; },
      singleton: function(item) { var value = new JHashSet([requireValue(item)]); metadata(value).readOnly = true; return value; },
      emptyMap: function() { var value = new JHashMap(); metadata(value).readOnly = true; return value; },
      singletonMap: function(key, item) {
        var value = new JHashMap(); value.put(key, item); metadata(value).readOnly = true; return value;
      },
      addAll: function(collection) {
        var changed = false;
        var data = metadata(collection);
        if (!data || (data.kind !== 'list' && data.kind !== 'set')) throw new fail('Collections.addAll expects a mutable Java List/Set');
        mutable(data, true);
        for (var i = 1; i < arguments.length; i++) changed = collection.add(arguments[i]) || changed;
        return changed;
      },
      sort: function(value, comparator) { arity(arguments, 1, 2, 'Collections.sort'); sortList(value, comparator); },
      reverse: function(value) {
        var items = writableList(value).items;
        for (var i = 0; i < floor(items.length / 2); i++) {
          var j = items.length - i - 1, previous = items[i]; items[i] = items[j]; items[j] = previous;
        }
      },
      swap: function(value, first, second) {
        var items = writableList(value).items;
        first = index(first, items.length, false); second = index(second, items.length, false);
        var previous = items[first]; items[first] = items[second]; items[second] = previous;
      },
      shuffle: function(value) {
        arity(arguments, 1, 1, 'Collections.shuffle');
        var items = writableList(value).items;
        for (var i = items.length - 1; i > 0; i--) {
          var j = floor(random() * (i + 1)), previous = items[i]; items[i] = items[j]; items[j] = previous;
        }
      },
      fill: function(value, item) {
        requireValue(item); var items = writableList(value).items;
        for (var i = 0; i < items.length; i++) items[i] = item;
      },
      copy: function(destination, source) {
        var items = valuesOf(source), target = writableList(destination).items;
        if (items.length > target.length) throw new outOfBounds('Collections.copy destination is too small');
        for (var i = 0; i < items.length; i++) target[i] = items[i];
      },
      frequency: function(value, item) {
        var items = valuesOf(value), count = 0;
        for (var i = 0; i < items.length; i++) if (equal(items[i], item)) count++;
        return count;
      },
      disjoint: function(first, second) {
        var a = valuesOf(first), b = valuesOf(second);
        for (var i = 0; i < a.length; i++) if (find(b, a[i], false) >= 0) return false;
        return true;
      },
      binarySearch: function(value, key, comparator) {
        var items = valuesOf(value); return searchSorted(items, 0, items.length, key, comparator);
      },
      min: function(value, comparator) { return extreme(value, comparator, false); },
      max: function(value, comparator) { return extreme(value, comparator, true); },
      reverseOrder: function(comparator) {
        var compare = compareWith(comparator); return staticClass({ compare: function(a, b) { return compare(b, a); } });
      },
      list: function(enumeration) {
        if (!enumeration || typeof enumeration.hasMoreElements !== 'function' || typeof enumeration.nextElement !== 'function') {
          throw new fail('Collections.list requires an Enumeration');
        }
        var values = []; while (enumeration.hasMoreElements()) values[values.length] = enumeration.nextElement();
        return new JArrayList(values);
      },
      enumeration: function(value) {
        var data = metadata(value);
        var it = data && data.kind !== 'map' && data.kind !== 'scalar' && data.kind !== 'entry' ? iterator(data) : new JArrayList(valuesOf(value)).iterator();
        return staticClass({ hasMoreElements: it.hasNext, nextElement: it.next });
      }
    });
    function extreme(value, comparator, maximum) {
      var items = valuesOf(value), compare = compareWith(comparator);
      if (!items.length) throw new outOfBounds('NoSuchElementException: empty Java collection');
      var best = items[0];
      for (var i = 1; i < items.length; i++) if (maximum ? compare(items[i], best) > 0 : compare(items[i], best) < 0) best = items[i];
      return best;
    }
    function arrayRange(array, from, to) {
      if (!isArray(array)) throw new fail('Expected a JavaScript array');
      from = index(from, array.length, true); to = index(to, array.length, true);
      if (to < from) throw new outOfBounds('Invalid Java array range');
      return { from: from, to: to };
    }
    var JArrays = staticClass({
      asList: function(array) {
        if (arguments.length === 1 && isArray(array)) {
          var value = list(array, JArrayList, { fixed: true });
          metadata(value).items = array; return value;
        }
        return list(slice(arguments), JArrayList, { fixed: true });
      },
      toString: function(array) {
        arity(arguments, 1, 1, 'Arrays.toString');
        if (array === null) return 'null';
        var values = valuesOf(array), parts = [];
        for (var i = 0; i < values.length; i++) parts[i] = display(values[i], []);
        return '[' + join(parts, ', ') + ']';
      },
      equals: function(first, second) {
        arity(arguments, 2, 2, 'Arrays.equals');
        if (first === second) return true;
        if (first === null || second === null) return false;
        var a = valuesOf(first), b = valuesOf(second);
        if (a.length !== b.length) return false;
        for (var i = 0; i < a.length; i++) if (!equal(a[i], b[i])) return false;
        return true;
      },
      copyOf: function(array, length) {
        arity(arguments, 2, 2, 'Arrays.copyOf');
        var values = valuesOf(array); length = index(length, 2147483647, true);
        var output = []; for (var i = 0; i < length; i++) output[i] = i < values.length ? values[i] : null;
        return output;
      },
      copyOfRange: function(array, from, to) {
        arity(arguments, 3, 3, 'Arrays.copyOfRange');
        var values = valuesOf(array); from = index(from, values.length, true); to = index(to, 2147483647, true);
        if (to < from) throw new outOfBounds('Invalid Arrays.copyOfRange range');
        var output = []; for (var i = from; i < to; i++) output[i - from] = i < values.length ? values[i] : null;
        return output;
      },
      sort: function(array, from, to, comparator) {
        arity(arguments, 1, 4, 'Arrays.sort');
        if (arguments.length <= 2) { comparator = from; from = 0; to = array.length; }
        var range = arrayRange(array, from, to), sorted = slice(array, range.from, range.to);
        sort(sorted, compareWith(comparator));
        for (var i = 0; i < sorted.length; i++) array[range.from + i] = sorted[i];
      },
      fill: function(array, from, to, value) {
        if (arguments.length === 2) { value = from; from = 0; to = array.length; }
        else arity(arguments, 4, 4, 'Arrays.fill');
        requireValue(value); var range = arrayRange(array, from, to);
        for (var i = range.from; i < range.to; i++) array[i] = value;
      },
      binarySearch: function(array, from, to, key, comparator) {
        arity(arguments, 2, 5, 'Arrays.binarySearch');
        if (arguments.length <= 3) { comparator = to; key = from; from = 0; to = array.length; }
        var range = arrayRange(array, from, to); return searchSorted(array, range.from, range.to, key, comparator);
      }
    });
""".trimIndent()
