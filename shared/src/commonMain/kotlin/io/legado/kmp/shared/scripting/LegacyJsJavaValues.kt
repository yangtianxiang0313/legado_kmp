package io.legado.kmp.shared.scripting

internal val LEGACY_JS_JAVA_VALUES = """
    function doubleText(value) {
      if (!finite(value)) return string(value);
      if (value === 0) return same(value, -0) ? '-0.0' : '0.0';
      var absolute = value < 0 ? -value : value;
      if (absolute >= 0.001 && absolute < 10000000) return string(value) + (integer(value) ? '.0' : '');
      var scientific = numberExponential(value), at = stringIndex(scientific, 'e');
      var mantissa = stringSlice(scientific, 0, at);
      return mantissa + (stringIndex(mantissa, '.') < 0 ? '.0' : '') + 'E' + string(number(stringSlice(scientific, at + 1)));
    }
    function scalar(ctor, type, value) {
      var target = create(ctor.prototype);
      stateSet(target, { kind: 'scalar', type: type, value: value });
      method(target, 'valueOf', function() { return value; });
      method(target, primitiveKey, function(hint) { return hint === 'string' ? type === 'Double' ? doubleText(value) : string(value) : value; });
      method(target, 'toJSON', function() { return value; });
      method(target, 'toString', function() {
        if (type === 'Double') return doubleText(value);
        return string(value);
      });
      method(target, 'equals', function(other) {
        var data = metadata(other);
        return !!data && data.kind === 'scalar' && data.type === type && same(data.value, value);
      });
      if (type === 'Boolean') {
        method(target, 'booleanValue', function() { return value; });
        method(target, 'compareTo', function(other) { return compareWith(null)(value, unbox(other)); });
      }
      else if (type !== 'String') {
        method(target, 'intValue', function() {
          if (type === 'Integer' || type === 'Long') return value | 0;
          if (value !== value) return 0;
          return value >= 2147483647 ? 2147483647 : value <= -2147483648 ? -2147483648 : trunc(value);
        });
        method(target, 'longValue', function() {
          if (value !== value) return 0;
          if (!safeInteger(trunc(value))) throw new outOfBounds('Java Long outside exact JavaScript integer range');
          return trunc(value);
        });
        method(target, 'doubleValue', function() { return value; });
        method(target, 'floatValue', function() { return fround(value); });
        method(target, 'byteValue', function() { var v = target.intValue() & 255; return v >= 128 ? v - 256 : v; });
        method(target, 'shortValue', function() { var v = target.intValue() & 65535; return v >= 32768 ? v - 65536 : v; });
        method(target, 'compareTo', function(other) { return compareWith(null)(value, unbox(other)); });
      }
      return target;
    }
    function text(value) {
      if (value == null) throw new fail('NullPointerException: expected a non-null string');
      return string(unbox(value));
    }
    function byteSource(value) {
      if (isArray(value)) return { items: value, length: value.length, array: true };
      if (value === null || typeof value !== 'object') return null;
      if (bufferIsView(value)) {
        // Native slot getters cannot be spoofed by constructor names, toStringTag, or own buffer fields.
        var kind = invoke(typedArrayKind, value);
        if (kind !== 'Int8Array' && kind !== 'Uint8Array' && kind !== 'Uint8ClampedArray') {
          throw new fail('Expected an 8-bit byte view, not ' + (kind || 'DataView'));
        }
        var length = invoke(typedArrayLength, value);
        return {
          items: new NativeUint8Array(invoke(typedArrayBuffer, value), invoke(typedArrayOffset, value), length),
          length: length, array: false
        };
      }
      var length;
      try { length = invoke(bufferLength, value); }
      catch (ignored) { return null; }
      return { items: new NativeUint8Array(value, 0, length), length: length, array: false };
    }
    function copyBytes(source) {
      var bytes = [];
      for (var i = 0; i < source.length; i++) {
        if (source.array && !own(source.items, i)) throw new outOfBounds('Sparse arrays are not Java byte arrays');
        var byte = unbox(source.items[i]);
        if (typeof byte !== 'number' || !integer(byte) || byte < -128 || byte > 255) throw new outOfBounds('Invalid Java byte value');
        field(bytes, i, byte & 255);
      }
      return bytes;
    }
    function byteArray(value) {
      var source = byteSource(value);
      if (!source) throw new fail('Expected a byte array, ArrayBuffer, or 8-bit typed array');
      return copyBytes(source);
    }
    function JString(value, charset, length, rangeCharset) {
      arity(arguments, 0, 4, 'String');
      var source = arguments.length === 0 ? null : byteSource(value);
      var content;
      if (arguments.length === 0) content = '';
      else if (source) {
        var bytes = copyBytes(source);
        if (arguments.length >= 3) {
          var start = index(charset, bytes.length, true);
          length = index(length, bytes.length - start, true);
          bytes = slice(bytes, start, start + length); charset = rangeCharset;
        }
        content = bytesToStr(stringify(bytes), charset == null ? null : text(charset));
      } else {
        arity(arguments, 1, 1, 'String'); content = text(value);
      }
      var target = scalar(JString, 'String', content);
      method(target, 'length', function() { return content.length; });
      method(target, 'isEmpty', function() { return content.length === 0; });
      method(target, 'getBytes', function(charset) {
        arity(arguments, 0, 1, 'String.getBytes');
        return byteArray(strToBytes(content, charset == null ? null : text(charset)));
      });
      method(target, 'charAt', function(at) { return charAt(content, index(at, content.length, false)); });
      method(target, 'toCharArray', function() { return split(content, ''); });
      method(target, 'substring', function(from, to) {
        from = index(from, content.length, true); to = to === undefined ? content.length : index(to, content.length, true);
        if (to < from) throw new outOfBounds('Invalid Java String substring range');
        return JString(stringSlice(content, from, to));
      });
      method(target, 'subSequence', target.substring);
      method(target, 'contains', function(part) { return stringIndex(content, text(part)) >= 0; });
      method(target, 'startsWith', function(part, from) {
        part = text(part); from = from === undefined ? 0 : number(unbox(from));
        return integer(from) && from >= 0 && from <= content.length && stringSlice(content, from, from + part.length) === part;
      });
      method(target, 'endsWith', function(part) { part = text(part); return part.length <= content.length && stringSlice(content, content.length - part.length) === part; });
      method(target, 'indexOf', function(part, from) { return stringIndex(content, text(part), from === undefined ? 0 : number(unbox(from))); });
      method(target, 'lastIndexOf', function(part, from) {
        return from === undefined ? stringLastIndex(content, text(part)) : stringLastIndex(content, text(part), number(unbox(from)));
      });
      method(target, 'equals', function(other) { return typeof unbox(other) === 'string' && unbox(other) === content; });
      method(target, 'equalsIgnoreCase', function(other) { return other != null && lower(text(other)) === lower(content); });
      method(target, 'compareTo', function(other) {
        other = text(other);
        var length = content.length < other.length ? content.length : other.length;
        for (var i = 0; i < length; i++) { var difference = charCodeAt(content, i) - charCodeAt(other, i); if (difference) return difference; }
        return content.length - other.length;
      });
      method(target, 'concat', function(other) { return JString(content + text(other)); });
      method(target, 'trim', function() {
        var from = 0, to = content.length;
        while (from < to && charCodeAt(content, from) <= 32) from++;
        while (to > from && charCodeAt(content, to - 1) <= 32) to--;
        return JString(stringSlice(content, from, to));
      });
      method(target, 'toLowerCase', function() { arity(arguments, 0, 0, 'String.toLowerCase'); return JString(lower(content)); });
      method(target, 'toUpperCase', function() { arity(arguments, 0, 0, 'String.toUpperCase'); return JString(upper(content)); });
      method(target, 'replace', function(before, after) {
        before = text(before); after = text(after);
        if (before === '') {
          var output = after;
          for (var i = 0; i < content.length; i++) output += charAt(content, i) + after;
          return JString(output);
        }
        return JString(join(split(content, before), after));
      });
      return target;
    }
    JString.prototype = create(null);
    JString.valueOf = function(value) { return JString(value === null ? 'null' : string(unbox(value))); };
    JString.copyValueOf = function(chars, offset, count) {
      if (!isArray(chars)) throw new fail('String.copyValueOf expects a char array');
      var start = offset === undefined ? 0 : index(offset, chars.length, true);
      count = count === undefined ? chars.length - start : index(count, chars.length - start, true);
      var output = '';
      for (var i = start; i < start + count; i++) {
        var value = unbox(chars[i]);
        if (typeof value !== 'string' || value.length !== 1) throw new fail('Expected single UTF-16 characters');
        output += value;
      }
      return JString(output);
    };
    function parseIntegral(value, radix, minimum, maximum) {
      value = text(value);
      radix = radix === undefined ? 10 : number(unbox(radix));
      if (!integer(radix) || radix < 2 || radix > 36 || value.length === 0) throw new fail('NumberFormatException: invalid integer or radix');
      var negative = charAt(value, 0) === '-', start = negative || charAt(value, 0) === '+' ? 1 : 0;
      if (start === value.length) throw new fail('NumberFormatException: sign without digits');
      var result = 0;
      for (var i = start; i < value.length; i++) {
        var code = charCodeAt(lower(charAt(value, i)), 0);
        var digit = code >= 48 && code <= 57 ? code - 48 : code >= 97 && code <= 122 ? code - 87 : -1;
        if (digit < 0 || digit >= radix) throw new fail('NumberFormatException: invalid integer digit');
        result = result * radix + digit;
        if (!safeInteger(result)) throw new outOfBounds('Java integer outside exact JavaScript range');
      }
      result = negative ? -result : result;
      if (result < minimum || result > maximum) throw new outOfBounds('NumberFormatException: Java integer overflow');
      return result === 0 ? 0 : result;
    }
    function integral(value, radix, minimum, maximum) {
      value = unbox(value);
      if (typeof value !== 'number') return parseIntegral(value, radix, minimum, maximum);
      if (!safeInteger(value) || value < minimum || value > maximum) throw new outOfBounds('Java integer outside supported exact range');
      return value === 0 ? 0 : value;
    }
    function JInteger(value) {
      arity(arguments, 1, 1, 'Integer'); return scalar(JInteger, 'Integer', integral(value, undefined, -2147483648, 2147483647));
    }
    function JLong(value) {
      arity(arguments, 1, 1, 'Long'); return scalar(JLong, 'Long', integral(value, undefined, -9007199254740991, 9007199254740991));
    }
    JInteger.prototype = create(null); JLong.prototype = create(null);
    JInteger.parseInt = function(value, radix) { return parseIntegral(value, radix, -2147483648, 2147483647); };
    JLong.parseLong = function(value, radix) { return parseIntegral(value, radix, -9007199254740991, 9007199254740991); };
    JInteger.valueOf = function(value, radix) { return JInteger(integral(value, radix, -2147483648, 2147483647)); };
    JLong.valueOf = function(value, radix) { return JLong(integral(value, radix, -9007199254740991, 9007199254740991)); };
    function integralString(value, radix) {
      value = unbox(value); radix = radix === undefined ? 10 : number(unbox(radix));
      if (!integer(radix) || radix < 2 || radix > 36) radix = 10;
      return numberString(value, radix);
    }
    JInteger.toString = function(value, radix) { return integralString(integral(value, undefined, -2147483648, 2147483647), radix); };
    JLong.toString = function(value, radix) { return integralString(integral(value, undefined, -9007199254740991, 9007199254740991), radix); };
    JInteger.toHexString = function(value) { return numberString(integral(value, undefined, -2147483648, 2147483647) >>> 0, 16); };
    JInteger.toBinaryString = function(value) { return numberString(integral(value, undefined, -2147483648, 2147483647) >>> 0, 2); };
    JInteger.toOctalString = function(value) { return numberString(integral(value, undefined, -2147483648, 2147483647) >>> 0, 8); };
    JInteger.MIN_VALUE = -2147483648; JInteger.MAX_VALUE = 2147483647; JInteger.SIZE = 32; JInteger.BYTES = 4;
    JLong.SIZE = 64; JLong.BYTES = 8;
    function parseDouble(value) {
      value = trim(text(value));
      if (value === 'NaN' || value === '+NaN' || value === '-NaN') return NaN;
      if (value === 'Infinity' || value === '+Infinity') return Infinity;
      if (value === '-Infinity') return -Infinity;
      if (!regexTest(/^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?[fFdD]?$/, value)) {
        throw new fail('NumberFormatException: unsupported/invalid Java Double literal');
      }
      if (regexTest(/[fFdD]$/, value)) value = stringSlice(value, 0, -1);
      return number(value);
    }
    function JDouble(value) {
      arity(arguments, 1, 1, 'Double'); value = unbox(value);
      return scalar(JDouble, 'Double', typeof value === 'number' ? value : parseDouble(value));
    }
    JDouble.prototype = create(null); JDouble.parseDouble = parseDouble; JDouble.valueOf = JDouble;
    JDouble.isNaN = function(value) { value = number(unbox(value)); return value !== value; };
    JDouble.isInfinite = function(value) { value = number(unbox(value)); return value === Infinity || value === -Infinity; };
    JDouble.isFinite = function(value) { return finite(unbox(value)); };
    JDouble.toString = function(value) { return JDouble(value).toString(); };
    JDouble.NaN = NaN; JDouble.POSITIVE_INFINITY = Infinity; JDouble.NEGATIVE_INFINITY = -Infinity;
    JDouble.MAX_VALUE = Number.MAX_VALUE; JDouble.MIN_VALUE = Number.MIN_VALUE; JDouble.SIZE = 64; JDouble.BYTES = 8;
    function bool(value) { value = unbox(value); return typeof value === 'boolean' ? value : value != null && lower(string(value)) === 'true'; }
    function JBoolean(value) { arity(arguments, 1, 1, 'Boolean'); return scalar(JBoolean, 'Boolean', bool(value)); }
    JBoolean.prototype = create(null); JBoolean.parseBoolean = bool;
    JBoolean.TRUE = JBoolean(true); JBoolean.FALSE = JBoolean(false);
    JBoolean.valueOf = function(value) { return bool(value) ? JBoolean.TRUE : JBoolean.FALSE; };
    JBoolean.toString = function(value) { return bool(value) ? 'true' : 'false'; };
    JInteger.compare = JLong.compare = JDouble.compare = JBoolean.compare = function(first, second) {
      return compareWith(null)(unbox(first), unbox(second));
    };

    var JTextUtils = staticClass({
      isEmpty: function(value) { return value == null || text(value).length === 0; },
      equals: function(first, second) { return first == null || second == null ? first == null && second == null : text(first) === text(second); },
      join: function(delimiter, values) {
        var items = valuesOf(values), parts = [];
        for (var i = 0; i < items.length; i++) parts[i] = string(unbox(items[i]));
        return join(parts, text(delimiter));
      }
    });

    function asciiBytes(value) {
      var bytes = [];
      for (var i = 0; i < value.length; i++) bytes[i] = charCodeAt(value, i);
      return bytes;
    }
    function base64Text(bytes, url, padding, width, separator, trailing) {
      bytes = byteArray(bytes);
      var alphabet = url ? 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_' : 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      var output = '';
      for (var i = 0; i < bytes.length; i += 3) {
        var a = bytes[i], b = i + 1 < bytes.length ? bytes[i + 1] : 0, c = i + 2 < bytes.length ? bytes[i + 2] : 0;
        output += charAt(alphabet, a >>> 2) + charAt(alphabet, ((a & 3) << 4) | (b >>> 4));
        if (i + 1 < bytes.length) output += charAt(alphabet, ((b & 15) << 2) | (c >>> 6)); else if (padding) output += '=';
        if (i + 2 < bytes.length) output += charAt(alphabet, c & 63); else if (padding) output += '=';
      }
      if (!width || output === '') return output;
      var lines = [];
      for (var i = 0; i < output.length; i += width) lines[lines.length] = stringSlice(output, i, i + width);
      return join(lines, separator) + (trailing ? separator : '');
    }
    function decode64(value, url, mime, android) {
      var input;
      if (typeof unbox(value) === 'string') input = unbox(value);
      else {
        var bytes = byteArray(value); input = '';
        for (var i = 0; i < bytes.length; i++) input += fromCharCode(bytes[i]);
      }
      var alphabet = url ? 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_' : 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      var clean = '';
      for (var i = 0; i < input.length; i++) {
        var character = charAt(input, i);
        if (character === '=' || stringIndex(alphabet, character) >= 0) clean += character;
        else if (android && (character === ' ' || character === '\n' || character === '\r' || character === '\t')) continue;
        else if (!mime) throw new fail('IllegalArgumentException: invalid Base64 character');
      }
      if (clean === '') return [];
      var padding = stringIndex(clean, '=');
      var count = padding < 0 ? clean.length : padding;
      var remainder = count % 4;
      if (remainder === 1 || (padding >= 0 &&
          (clean.length % 4 !== 0 || clean.length - count !== (remainder === 2 ? 2 : remainder === 3 ? 1 : 0)))) {
        throw new fail('IllegalArgumentException: invalid Base64 padding');
      }
      for (var i = count; i < clean.length; i++) if (charAt(clean, i) !== '=') throw new fail('IllegalArgumentException: data after Base64 padding');
      var decoded = base64DecodeBytes(clean, url ? 8 : 0);
      if (decoded == null) throw new fail('IllegalArgumentException: invalid Base64 data');
      return byteArray(decoded);
    }
    function encoder(url, padding, width, separator) {
      return staticClass({
        encodeToString: function(bytes) { arity(arguments, 1, 1, 'Base64.Encoder.encodeToString'); return base64Text(bytes, url, padding, width, separator, false); },
        encode: function(bytes) { arity(arguments, 1, 1, 'Base64.Encoder.encode'); return asciiBytes(base64Text(bytes, url, padding, width, separator, false)); },
        withoutPadding: function() { return encoder(url, false, width, separator); }
      });
    }
    function decoder(url, mime) {
      return staticClass({ decode: function(value) { arity(arguments, 1, 1, 'Base64.Decoder.decode'); return decode64(value, url, mime, false); } });
    }
    var JBase64 = staticClass({
      getEncoder: function() { return encoder(false, true, 0, ''); },
      getUrlEncoder: function() { return encoder(true, true, 0, ''); },
      getMimeEncoder: function() { arity(arguments, 0, 0, 'Base64.getMimeEncoder'); return encoder(false, true, 76, '\r\n'); },
      getDecoder: function() { return decoder(false, false); },
      getUrlDecoder: function() { return decoder(true, false); },
      getMimeDecoder: function() { return decoder(false, true); }
    });
    function androidBase64Args(args) {
      if (args.length !== 2 && args.length !== 4) throw new fail('Unsupported android.util.Base64 overload');
      var value = args[0], flags;
      if (args.length === 4) {
        var bytes = byteArray(value), start = index(args[1], bytes.length, true), length = index(args[2], bytes.length - start, true);
        value = slice(bytes, start, start + length); flags = args[3];
      } else flags = args[1];
      flags = number(unbox(flags));
      if (!integer(flags) || flags < 0 || flags > 31) throw new fail('Unsupported android.util.Base64 flags');
      return { value: value, flags: flags };
    }
    function androidEncode(args) {
      var input = androidBase64Args(args), flags = input.flags;
      return base64Text(input.value, !!(flags & 8), !(flags & 1), flags & 2 ? 0 : 76, flags & 4 ? '\r\n' : '\n', true);
    }
    var JAndroidBase64 = staticClass({
      DEFAULT: 0, NO_PADDING: 1, NO_WRAP: 2, CRLF: 4, URL_SAFE: 8, NO_CLOSE: 16,
      encodeToString: function() { return androidEncode(arguments); },
      encode: function() { return asciiBytes(androidEncode(arguments)); },
      decode: function() { var input = androidBase64Args(arguments); return decode64(input.value, !!(input.flags & 8), false, true); }
    });
""".trimIndent()
