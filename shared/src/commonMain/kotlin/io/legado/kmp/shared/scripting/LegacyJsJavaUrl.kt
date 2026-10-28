package io.legado.kmp.shared.scripting

// Java form semantics are separate from the existing reading host's URI/String helpers.
internal val LEGACY_JS_JAVA_URL = """
    function formCharset(args, name) {
      arity(args, 1, 2, name);
      var charset = args.length === 1 ? 'UTF-8' : upper(text(args[1]));
      if (charset === 'UTF8' || charset === 'UTF-8') return 'UTF-8';
      if (charset === 'ASCII' || charset === 'US-ASCII') return 'ASCII';
      if (charset === 'ISO-8859-1' || charset === 'ISO8859-1' || charset === 'ISO8859_1' || charset === 'LATIN1') return 'ISO-8859-1';
      if (charset === 'UTF16' || charset === 'UTF-16') return 'UTF-16';
      if (charset === 'UTF16LE' || charset === 'UTF-16LE') return 'UTF-16LE';
      if (charset === 'UTF16BE' || charset === 'UTF-16BE') return 'UTF-16BE';
      if (charset === 'GBK' || charset === 'GB2312') return charset;
      if (charset === 'GB18030' || charset === 'GB_18030') return 'GB18030';
      if (charset === 'BIG5' || charset === 'BIG-5') return 'BIG5';
      throw new fail('UnsupportedEncodingException: unsupported Java form charset ' + charset);
    }
    function sameFormBytes(first, second) {
      if (first.length !== second.length) return false;
      for (var i = 0; i < first.length; i++) if (first[i] !== second[i]) return false;
      return true;
    }
    function legacyFormUnit(bytes, offset, charset) {
      var first = bytes[offset], second = bytes[offset + 1], third = bytes[offset + 2];
      if (first <= 127) return 1;
      if (charset === 'GB2312') {
        if (first >= 161 && first <= 247 && second >= 161 && second <= 254) return 2;
      } else if (charset === 'BIG5') {
        if (first >= 129 && first <= 254 && (second >= 64 && second <= 126 || second >= 161 && second <= 254)) return 2;
      } else if (first >= 129 && first <= 254) {
        if (charset === 'GB18030' && second >= 48 && second <= 57 && third >= 129 && third <= 254 &&
            bytes[offset + 3] >= 48 && bytes[offset + 3] <= 57) return 4;
        if (second >= 64 && second <= 254 && second !== 127) return 2;
      }
      return 0;
    }
    function formUnicodeText(value, charset) {
      var output = '', limit = charset === 'ASCII' ? 127 : charset === 'ISO-8859-1' ? 255 : -1;
      var replacement = stringIndex(charset, 'UTF-16') === 0 ? fromCharCode(65533) : '?';
      for (var i = 0; i < value.length; i++) {
        var code = charCodeAt(value, i), part = charAt(value, i);
        if (code >= 55296 && code <= 56319 && i + 1 < value.length &&
            charCodeAt(value, i + 1) >= 56320 && charCodeAt(value, i + 1) <= 57343) {
          part += charAt(value, ++i);
          output += limit < 0 ? part : '?';
        } else if (code >= 55296 && code <= 57343) output += replacement;
        else output += limit >= 0 && code > limit ? '?' : part;
      }
      return output;
    }
    function formEncodeBytes(value, charset) {
      value = formUnicodeText(value, charset);
      if (charset === 'UTF-16') {
        var encoded = byteArray(strToBytes(value, 'UTF-16BE')), marked = [254, 255];
        for (var i = 0; i < encoded.length; i++) marked[marked.length] = encoded[i];
        return marked;
      }
      if (charset === 'UTF-8' || charset === 'ASCII' || charset === 'ISO-8859-1' || stringIndex(charset, 'UTF-16') === 0) {
        return byteArray(strToBytes(value, charset));
      }
      var output = [];
      // The platform codec can fall back to UTF-8: never publish that fallback as a legacy charset.
      for (var i = 0; i < value.length; i++) {
        var part = charAt(value, i), code = charCodeAt(value, i);
        if (code >= 55296 && code <= 56319) part += charAt(value, ++i);
        var bytes = byteArray(strToBytes(part, charset));
        var unit = bytes.length && legacyFormUnit(bytes, 0, charset);
        if (unit !== bytes.length || bytesToStr(stringify(bytes), charset) !== part) bytes = [63];
        for (var bi = 0; bi < bytes.length; bi++) output[output.length] = bytes[bi];
      }
      return output;
    }
    function formDecodeUtf8(bytes) {
      var output = '', start = 0, i = 0;
      while (i < bytes.length) {
        var first = bytes[i];
        if (first < 128) { i++; continue; }
        var count = first >= 194 && first <= 223 ? 2 : first >= 224 && first <= 239 ? 3 : first >= 240 && first <= 244 ? 4 : 0;
        var malformed = count ? 0 : 1;
        for (var j = 1; j < count; j++) {
          var next = bytes[i + j];
          if (i + j >= bytes.length || next < 128 || next > 191 || j === 1 &&
              (first === 224 && next < 160 || first === 240 && next < 144 || first === 244 && next > 143)) {
            malformed = j; break;
          }
        }
        // Java replaces an encoded surrogate as one malformed three-byte sequence.
        if (!malformed && count === 3 && first === 237 && bytes[i + 1] >= 160) malformed = 3;
        if (malformed) {
          if (i > start) output += bytesToStr(stringify(slice(bytes, start, i)), null);
          output += fromCharCode(65533); i += malformed; start = i;
        } else i += count;
      }
      if (i > start) output += bytesToStr(stringify(slice(bytes, start, i)), null);
      return output;
    }
    function formDecodeUtf16(bytes, charset) {
      var little = charset === 'UTF-16LE', offset = 0, output = '';
      if (charset === 'UTF-16' && bytes.length >= 2) {
        if (bytes[0] === 254 && bytes[1] === 255) offset = 2;
        else if (bytes[0] === 255 && bytes[1] === 254) { little = true; offset = 2; }
      }
      function unit(at) { return little ? bytes[at] | bytes[at + 1] << 8 : bytes[at] << 8 | bytes[at + 1]; }
      while (offset < bytes.length) {
        if (offset + 1 === bytes.length) { output += fromCharCode(65533); break; }
        var code = unit(offset); offset += 2;
        if (code >= 55296 && code <= 56319) {
          if (offset + 1 >= bytes.length) { output += fromCharCode(65533); break; }
          var lowCode = unit(offset); offset += 2;
          output += lowCode >= 56320 && lowCode <= 57343 ? fromCharCode(code, lowCode) : fromCharCode(65533);
        } else output += fromCharCode(code >= 56320 && code <= 57343 ? 65533 : code);
      }
      return output;
    }
    function formDecodeBytes(bytes, charset) {
      if (charset === 'UTF-8') return formDecodeUtf8(bytes);
      if (stringIndex(charset, 'UTF-16') === 0) return formDecodeUtf16(bytes, charset);
      var output = '';
      if (charset === 'ASCII' || charset === 'ISO-8859-1') {
        for (var i = 0; i < bytes.length; i++) output += fromCharCode(charset === 'ASCII' && bytes[i] > 127 ? 65533 : bytes[i]);
        return output;
      }
      for (var i = 0; i < bytes.length;) {
        var count = legacyFormUnit(bytes, i, charset);
        if (!count) { output += fromCharCode(65533); i++; continue; }
        var part = slice(bytes, i, i + count), decoded = bytesToStr(stringify(part), charset);
        var encoded = byteArray(strToBytes(decoded, charset));
        output += sameFormBytes(part, encoded) ? decoded : fromCharCode(65533);
        i += count;
      }
      return output;
    }
    function safeFormChar(code) {
      return code >= 65 && code <= 90 || code >= 97 && code <= 122 || code >= 48 && code <= 57 ||
        code === 45 || code === 95 || code === 46 || code === 42 || code === 32;
    }
    var JURLEncoder = staticClass({ encode: function(value, charset) {
      charset = formCharset(arguments, 'URLEncoder.encode'); value = text(value);
      var output = '', alphabet = '0123456789ABCDEF';
      for (var i = 0; i < value.length;) {
        var code = charCodeAt(value, i);
        if (safeFormChar(code)) { output += code === 32 ? '+' : charAt(value, i); i++; }
        else {
          var start = i++;
          while (i < value.length && !safeFormChar(charCodeAt(value, i))) i++;
          var bytes = formEncodeBytes(stringSlice(value, start, i), charset);
          for (var bi = 0; bi < bytes.length; bi++) output += '%' + charAt(alphabet, bytes[bi] >>> 4) + charAt(alphabet, bytes[bi] & 15);
        }
      }
      return JString(output);
    } });
    var JURLDecoder = staticClass({ decode: function(value, charset) {
      charset = formCharset(arguments, 'URLDecoder.decode'); value = text(value);
      var output = '';
      for (var i = 0; i < value.length;) {
        var character = charAt(value, i);
        if (character === '+') { output += ' '; i++; }
        else if (character === '%') {
          var bytes = [];
          while (i < value.length && charAt(value, i) === '%') {
            if (i + 2 >= value.length) throw new fail('IllegalArgumentException: incomplete URL escape');
            if (stringIndex('0123456789ABCDEF', upper(charAt(value, i + 1))) < 0 ||
                stringIndex('0123456789ABCDEF', upper(charAt(value, i + 2))) < 0) {
              throw new fail('IllegalArgumentException: invalid URL escape');
            }
            var byte = parseIntegral(stringSlice(value, i + 1, i + 3), 16, -255, 255);
            if (byte < 0) throw new fail('IllegalArgumentException: negative URL escape');
            bytes[bytes.length] = byte; i += 3;
          }
          output += formDecodeBytes(bytes, charset);
        } else { output += character; i++; }
      }
      return JString(output);
    } });
""".trimIndent()
